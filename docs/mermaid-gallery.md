# Mermaid gallery

Every diagram kind Mermaid has added since version 10, one of each, so the
Markdown preview can be checked against all of them at once. Open this file in
Jeansh's file tab: it opens rendered, and each block below should be a picture
rather than text.

The app bundles **Mermaid 12.0.0**. Two things about 12 are worth knowing while
you look: it lays out with **ELK** rather than dagre, and it draws in its new
**neo** look, so these will not match a screenshot taken from an older Mermaid.

**A block that shows an error message instead of a diagram is still useful.**
It means either the syntax here is wrong or that kind is not in the bundle —
Jeansh prints what Mermaid said and then the source, so you can tell which.

One kind is deliberately missing: **ZenUML** (10.0) ships as a separate package
and is not in the bundle, so it would only ever show an error.

## Mindmap — 9.3

```mermaid
mindmap
  root((Jeansh))
    Terminal
      tmux
      xterm2
      Key bar
    Files
      SFTP
      Editor
      Markdown
    Database
      PostgreSQL
      MongoDB
      Redis
```

## Timeline — 9.4

```mermaid
timeline
    title Where the builds went
    1.0.36 : transport on its own isolate
    1.0.40 : the preview keeps its place
    1.0.45 : Mermaid 12 : a second address : the scroll comes back
```

## Quadrant chart — 9.4

```mermaid
quadrantChart
    title What to build next
    x-axis "Little work" --> "Much work"
    y-axis "Small gain" --> "Large gain"
    quadrant-1 "Do now"
    quadrant-2 "Plan it"
    quadrant-3 "Leave it"
    quadrant-4 "Quick win"
    "Images in the preview": [0.4, 0.8]
    "Host key names the address": [0.25, 0.9]
    "Image paste": [0.6, 0.75]
    "A second alternative port": [0.2, 0.15]
```

## Sankey — 10.3

```mermaid
sankey-beta

Tailnet,Terminal,40
Tailnet,SFTP,25
Tailnet,Database,10
LAN,Terminal,15
LAN,SFTP,20
```

## XY chart — 10.3

```mermaid
xychart-beta
    title "Download speed, same file and server"
    x-axis ["debug 1.0.30", "profile 1.0.36", "isolate 1.0.45"]
    y-axis "MB/s" 0 --> 10
    bar [1.66, 3.5, 8.4]
    line [1.66, 3.5, 8.4]
```

## Block — 10.9

```mermaid
block-beta
  columns 3
  tablet["Tablet"] link["tailnet or LAN"] host["Host"]
  tablet --> link
  link --> host
```

## Packet — 11.0

```mermaid
packet
0-15: "Source port"
16-31: "Destination port"
32-63: "Sequence number"
64-95: "Acknowledgement number"
96-99: "Offset"
100-105: "Reserved"
106-111: "Flags"
112-127: "Window"
```

## Architecture — 11.1

```mermaid
architecture-beta
    group tailnet(cloud)[Tailnet]

    service tablet(server)[Tablet] in tailnet
    service host(server)[Host] in tailnet
    service db(database)[Postgres] in tailnet
    service files(disk)[Files] in tailnet

    tablet:R --> L:host
    host:R --> L:db
    host:B --> T:files
```

## Kanban — 11.3

```mermaid
kanban
  todo[To do]
    img[Images in the Markdown preview]
    fp[Host key names the address that answered]
  doing[Doing]
    paste[Pasting an image uploads it]
  done[Done]
    scroll[An armed CTRL keeps the scroll]
    place[The preview comes back where it was left]
    mermaid[Mermaid 12]
```

## Radar — 11.6

```mermaid
radar-beta
  axis speed["Transfer"], keys["Keyboard"], files["Files"], db["Database"], md["Markdown"]
  curve before["1.0.30"]{2, 3, 4, 4, 3}
  curve now["1.0.45"]{5, 4, 5, 5, 5}
  max 5
```

## Treemap — 11.6

```mermaid
treemap-beta
"Jeansh"
    "Terminal"
        "xterm2": 40
        "tmux": 15
    "Files"
        "SFTP": 25
        "Editor": 20
    "Database"
        "PostgreSQL": 12
        "MongoDB": 8
        "Redis": 6
```

## The older kinds, for comparison

These were here before 10 and are drawn by ELK now, so they are worth a look
too — this is where a layout change shows most.

```mermaid
sequenceDiagram
    participant T as Tablet
    participant H as Host
    T->>H: connect over the saved address
    T->>H: and the alternative, 250 ms later
    H-->>T: whichever answers first
    Note over T,H: the loser is dropped before a byte is written
```

```mermaid
flowchart TD
    A[Tap the host] --> B{Saved address answers?}
    B -- yes --> C[Connect, no toast]
    B -- no --> D[Alternative answers]
    D --> E[Connect, and say which address it was]
    B -- neither --> F[The saved address's error]
```

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Connecting: tap
    Connecting --> Trusting: a key we have not seen
    Trusting --> Open: trusted
    Trusting --> Idle: refused
    Connecting --> Open: a key we know
    Open --> Idle: closed
```
