// Command sshbox-notify sends a push notification to an sshbox device.
//
// It is meant to be dropped on any server you SSH into and called at the end
// of something slow:
//
//	sshbox-notify "build selesai"
//	sshbox-notify -title Deploy -host 1788717544349041 "selesai dalam 4m"
//
// Tapping the notification opens that host's terminal in sshbox, resuming the
// session if it is still open. The device and the host come from
// LC_SSHBOX_TOKEN and LC_SSHBOX_HOST_ID, which the app passes with every shell
// it opens; the config's tokens and host_id stand in where they are not set.
//
// Messages are sent data-only through FCM HTTP v1. That API requires OAuth2
// with a service account, which is why this is a Go binary rather than a
// curl one-liner: signing an RS256 JWT in shell is not worth anyone's evening.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const (
	fcmScope   = "https://www.googleapis.com/auth/firebase.messaging"
	fcmBaseURL = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
)

// config is read from ~/.config/sshbox-notify/config.json by default.
type config struct {
	// ServiceAccount is the path to a Firebase service account JSON, from
	// Project Settings -> Service Accounts -> Generate new private key.
	ServiceAccount string `json:"service_account"`

	// ProjectID is optional; it defaults to the one inside the service account.
	ProjectID string `json:"project_id"`

	// Tokens are the FCM registration tokens of the devices to notify, for a
	// shell without LC_SSHBOX_TOKEN: one on a server whose sshd refuses it.
	// Settings -> Notifications in the app copies the current one.
	Tokens []string `json:"tokens"`

	// HostID is the sshbox host a tap should open, for a shell without
	// LC_SSHBOX_HOST_ID. Usually the host entry that points at this very
	// server.
	HostID string `json:"host_id"`
}

func defaultConfigPath() string {
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "sshbox-notify", "config.json")
	}
	return filepath.Join(os.Getenv("HOME"), ".config", "sshbox-notify", "config.json")
}

func loadConfig(path string) (*config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("no config at %s\n\n%s", path, configHelp(path))
		}
		return nil, err
	}

	cfg := &config{}
	if err := json.Unmarshal(raw, cfg); err != nil {
		return nil, fmt.Errorf("%s is not valid JSON: %w", path, err)
	}
	return cfg, nil
}

func configHelp(path string) string {
	return fmt.Sprintf(`Create it like this:

  mkdir -p %s
  cat > %s <<'JSON'
  {
    "service_account": "/etc/sshbox/service-account.json"
  }
  JSON

The device to notify and the host to open come from LC_SSHBOX_TOKEN and
LC_SSHBOX_HOST_ID, which Jeansh sends with every shell. Where sshd refuses
them (it needs AcceptEnv LC_* in sshd_config), add them to the config:

    "tokens": ["<token from Settings -> Notifications in Jeansh>"],
    "host_id": "<host id this server corresponds to>"

The service account comes from the Firebase console:
Project Settings -> Service Accounts -> Generate new private key.
Keep it readable only by the user running this command.`,
		filepath.Dir(path), path)
}

// serviceAccountProjectID digs the project out of the credentials file so the
// config does not have to repeat it.
func serviceAccountProjectID(raw []byte) string {
	var probe struct {
		ProjectID string `json:"project_id"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return ""
	}
	return probe.ProjectID
}

type fcmAndroid struct {
	Priority string `json:"priority"`
}

type fcmNotification struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// Both halves are sent on purpose.
//
// The notification block is what Android displays while the app is
// backgrounded or dead — a data-only message would arrive silently, since
// displaying one requires a registered background isolate handler.
//
// The data block is what survives the tap: FCM hands the full message,
// including data, to onMessageOpenedApp and getInitialMessage, so the app
// still routes on hostId exactly as it does for a deep link.
type fcmMessage struct {
	Token        string            `json:"token"`
	Data         map[string]string `json:"data"`
	Notification fcmNotification   `json:"notification"`
	Android      fcmAndroid        `json:"android"`
}

type fcmEnvelope struct {
	Message fcmMessage `json:"message"`
}

func send(ctx context.Context, client *http.Client, projectID string, msg fcmMessage) error {
	body, err := json.Marshal(fcmEnvelope{Message: msg})
	if err != nil {
		return err
	}

	url := fmt.Sprintf(fcmBaseURL, projectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	detail, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	switch resp.StatusCode {
	case http.StatusNotFound, http.StatusGone:
		return fmt.Errorf("device token is no longer registered — copy a fresh one from sshbox (HTTP %d)", resp.StatusCode)
	case http.StatusUnauthorized, http.StatusForbidden:
		return fmt.Errorf("service account rejected; check it belongs to this project and has the Firebase Messaging role (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(detail)))
	default:
		return fmt.Errorf("FCM returned HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(detail)))
	}
}

func run() error {
	configPath := flag.String("config", defaultConfigPath(), "path to config.json")
	hostID := flag.String("host", "", "sshbox host id to open on tap (overrides LC_SSHBOX_HOST_ID and config)")
	title := flag.String("title", "sshbox", "notification title")
	token := flag.String("token", "", "send to this device token only (overrides LC_SSHBOX_TOKEN and config)")
	timeout := flag.Duration("timeout", 15*time.Second, "network timeout")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: %s [flags] <message>\n\nflags:\n", os.Args[0])
		flag.PrintDefaults()
	}
	flag.Parse()

	body := strings.TrimSpace(strings.Join(flag.Args(), " "))
	if body == "" {
		flag.Usage()
		return errors.New("no message given")
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		return err
	}

	// What the app gave the shell wins over the config, and the flags over
	// both.
	if env := os.Getenv("LC_SSHBOX_HOST_ID"); env != "" {
		cfg.HostID = env
	}
	if *hostID != "" {
		cfg.HostID = *hostID
	}
	if cfg.HostID == "" {
		return errors.New("no LC_SSHBOX_HOST_ID, no host_id in config and no -host given; a notification with nothing to open is not much use")
	}

	tokens := cfg.Tokens
	if env := os.Getenv("LC_SSHBOX_TOKEN"); env != "" {
		tokens = []string{env}
	}
	if *token != "" {
		tokens = []string{*token}
	}
	if len(tokens) == 0 {
		return fmt.Errorf("no LC_SSHBOX_TOKEN and no device tokens configured\n\n%s", configHelp(*configPath))
	}

	if cfg.ServiceAccount == "" {
		return errors.New("no service_account path in config")
	}
	credentials, err := os.ReadFile(cfg.ServiceAccount)
	if err != nil {
		return fmt.Errorf("cannot read service account: %w", err)
	}

	projectID := cfg.ProjectID
	if projectID == "" {
		projectID = serviceAccountProjectID(credentials)
	}
	if projectID == "" {
		return errors.New("could not determine project id; set project_id in the config")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	creds, err := google.CredentialsFromJSON(ctx, credentials, fcmScope)
	if err != nil {
		return fmt.Errorf("service account is not usable: %w", err)
	}
	// Handles fetching and refreshing the bearer token for us.
	httpClient := oauth2.NewClient(ctx, creds.TokenSource)

	var failures int
	for _, deviceToken := range tokens {
		msg := fcmMessage{
			Token: deviceToken,
			Data: map[string]string{
				"hostId": cfg.HostID,
				"title":  *title,
				"body":   body,
			},
			Notification: fcmNotification{Title: *title, Body: body},
			Android:      fcmAndroid{Priority: "high"},
		}

		if err := send(ctx, httpClient, projectID, msg); err != nil {
			failures++
			fmt.Fprintf(os.Stderr, "%s: %v\n", shorten(deviceToken), err)
			continue
		}
		fmt.Printf("sent to %s\n", shorten(deviceToken))
	}

	if failures == len(tokens) {
		return errors.New("every device failed")
	}
	return nil
}

// shorten keeps logs readable; a full FCM token is ~160 characters.
func shorten(token string) string {
	if len(token) <= 16 {
		return token
	}
	return token[:8] + "…" + token[len(token)-6:]
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "sshbox-notify: %v\n", err)
		os.Exit(1)
	}
}
