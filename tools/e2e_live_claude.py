"""A stand-in for an interactive Claude Code session, run in a tmux pane.

It is what chat's typing into a running session checks for, and nothing
more: its state file in ~/.claude/sessions/<pid>.json naming its session,
idle and waiting for nothing; a ❯ input line with the cursor just after it;
and the pane's foreground. Each line typed at it — from the chat, which types
into the pane, or at the pane itself — goes into its transcript as the user's
turn, followed by an answer, which chat reads back as it follows the
transcript. A line starting with `/` is a command instead, recorded as 2.1.286
records one it runs itself: a `system` line of subtype `local_command` holding
its name, message and arguments in tags, then another with what it printed.

A line starting `tasks:` plays a turn that makes three tasks (TaskCreate, each
with its result) and moves the first to in progress, then completed, so chat's
checklist can be seen to follow; the session's task store, ~/.claude/tasks/<id>/,
is written to match, with seven earlier tasks no transcript carries. A line starting `slow:` plays a slow turn instead, shaped on one 2.1.286
wrote: the prompt with its time, a message calling Bash with its usage four
seconds later, the result four seconds after that, then a closing message of
two lines sharing one message id and the turn's duration. Meanwhile its row
in the stand-in listing, ~/.e2e-agents.json, says busy, as `claude agents`
says of a session mid-turn. A line starting `wait:` stops at a permission
prompt instead: its row says waiting, with waitingFor, for twenty seconds.
A line starting `long:` writes six long answers after five seconds, for a
chat put behind another tab meanwhile to come back following.

    python3 e2e_live_claude.py SESSION_ID

tools/e2e_android.sh runs it on the runner's throwaway host user only.
"""

import datetime
import json
import os
import sys
import time

session = sys.argv[1]
# Pictures (#146): a raw-mode input line, `claude -p` and `claude --bg`, kept
# apart in e2e_image_claude.py beside this file.
if session in ('--tui', '--stream', '--bg'):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import e2e_image_claude
    sys.exit(e2e_image_claude.main(sys.argv[1:]))
config = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.environ['HOME'], '.claude')
cwd = os.getcwd()
transcript = os.path.join(
    config, 'projects', cwd.replace('/', '-').replace('.', '-'), session + '.jsonl')
os.makedirs(os.path.dirname(transcript), exist_ok=True)
state = os.path.join(config, 'sessions', f'{os.getpid()}.json')
os.makedirs(os.path.dirname(state), exist_ok=True)
# Compact, as the CLI writes it: chat's host script greps "sessionId":"…".
with open(state, 'w') as f:
    json.dump({'pid': os.getpid(), 'sessionId': session, 'cwd': cwd,
               'kind': 'interactive', 'status': 'idle'}, f, separators=(',', ':'))


def record(event):
    with open(transcript, 'a') as f:
        f.write(json.dumps(event) + '\n')


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec='milliseconds').replace('+00:00', 'Z')


def listed_as(status, waiting_for=None):
    path = os.path.join(os.environ['HOME'], '.e2e-agents.json')
    try:
        rows = json.load(open(path))
    except (OSError, ValueError):
        return
    for row in rows:
        if row.get('sessionId') == session:
            row['status'] = status
            row.pop('waitingFor', None)
            if waiting_for:
                row['waitingFor'] = waiting_for
    json.dump(rows, open(path, 'w'))


def waiting_turn(text):
    """A turn stopped at a permission prompt: a Bash call that never gets a
    result while the listing says waiting, as `claude agents` says of a tool
    waiting to be approved; then, twenty seconds on, approved and done."""
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_w1', 'role': 'assistant', 'stop_reason': 'tool_use',
        'usage': {'output_tokens': 12},
        'content': [{'type': 'tool_use', 'id': 'toolu_e2e_w1', 'name': 'Bash',
                     'input': {'command': 'rm -rf /tmp/e2e-wait'}}]}})
    listed_as('waiting', 'permission prompt')
    time.sleep(20)
    listed_as('busy')
    record({'type': 'user', 'timestamp': now(), 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_e2e_w1', 'content': ''}]}})
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_w2', 'role': 'assistant', 'stop_reason': 'end_turn',
        'usage': {'output_tokens': 5},
        'content': [{'type': 'text', 'text': 'Waited answer: done'}]}})
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 20000,
            'timestamp': now()})
    listed_as('idle')
    sys.stdout.write('Waited answer: done\n')


def slow_turn(text):
    listed_as('busy')
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    time.sleep(4)
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_1', 'role': 'assistant', 'stop_reason': 'tool_use',
        'usage': {'output_tokens': 87},
        'content': [{'type': 'tool_use', 'id': 'toolu_e2e_1', 'name': 'Bash',
                     'input': {'command': 'sleep 2; echo done'}}]}})
    time.sleep(4)
    record({'type': 'user', 'timestamp': now(), 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_e2e_1', 'content': 'done'}]}})
    time.sleep(4)
    for block in ({'type': 'thinking', 'thinking': '', 'signature': 'e2e'},
                  {'type': 'text', 'text': 'Slow answer: done'}):
        record({'type': 'assistant', 'timestamp': now(), 'message': {
            'id': 'msg_e2e_2', 'role': 'assistant', 'stop_reason': 'end_turn',
            'usage': {'output_tokens': 1313}, 'content': [block]}})
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 12000,
            'timestamp': now()})
    listed_as('idle')
    sys.stdout.write('Slow answer: done\n')


def long_turn(text):
    """Five seconds' grace, for the chat to be put behind another tab, then
    six answers of twenty-five lines each, well over a screen, the last
    ending "Long answer 6 end"."""
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    time.sleep(5)
    for n in range(1, 7):
        lines = [f'Long answer {n}, line {k}' for k in range(1, 25)]
        record({'type': 'assistant', 'timestamp': now(), 'message': {
            'id': f'msg_e2e_l{n}', 'role': 'assistant',
            'stop_reason': 'end_turn' if n == 6 else None,
            'content': [{'type': 'text',
                         'text': '\n\n'.join(lines + [f'Long answer {n} end'])}]}})
        time.sleep(0.5)
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 8000,
            'timestamp': now()})
    sys.stdout.write('Long answer 6 end\n')


task_counter = [0]


store_dir = os.path.join(config, 'tasks', session)


def store(n, subject, status, active_form=None):
    """Task n in the session's own task store, as the CLI keeps it:
    ~/.claude/tasks/<sessionId>/<n>.json."""
    os.makedirs(store_dir, exist_ok=True)
    with open(os.path.join(store_dir, f'{n}.json'), 'w') as f:
        json.dump({'id': str(n), 'subject': subject, 'description': subject,
                   'activeForm': active_form or subject, 'status': status,
                   'blocks': [], 'blockedBy': []}, f, indent=2)


def task_turn(text):
    """A line starting `tasks:` plays a turn that makes three tasks and works
    through them, shaped like TaskCreate and TaskUpdate as 2.1.286 wrote them: a
    TaskCreate has no id, its result gives it (`Task #N created successfully`).
    """
    listed_as('busy')
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    # Seven tasks from long before, in the store and in no transcript chat
    # reads: a long session's, made early: five done and two still to do.
    for n in range(101, 106):
        store(n, f'Earlier done {n - 100}', 'completed')
    store(106, 'Earlier open one', 'pending')
    store(107, 'Earlier open two', 'pending')

    def call(name, tid, tool_input):
        record({'type': 'assistant', 'timestamp': now(), 'message': {
            'id': 'msg_' + tid, 'role': 'assistant', 'stop_reason': 'tool_use',
            'usage': {'output_tokens': 20},
            'content': [{'type': 'tool_use', 'id': tid, 'name': name, 'input': tool_input}]}})

    def result(tid, out):
        record({'type': 'user', 'timestamp': now(), 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': tid, 'content': out}]}})

    ids = []
    for name in ('Check the stand-in', 'Write the report', 'Ship it'):
        task_counter[0] += 1
        n = task_counter[0]
        ids.append(n)
        form = name.replace('Check', 'Checking')
        store(n, name, 'pending', form)
        call('TaskCreate', f'tc{n}', {'subject': name, 'description': name,
                                       'activeForm': form})
        result(f'tc{n}', f'Task #{n} created successfully: {name}')
    time.sleep(12)
    store(ids[0], 'Check the stand-in', 'in_progress', 'Checking the stand-in')
    call('TaskUpdate', f'tu{ids[0]}a', {'taskId': str(ids[0]), 'status': 'in_progress'})
    result(f'tu{ids[0]}a', f'Updated task #{ids[0]} status')
    time.sleep(12)
    store(ids[0], 'Check the stand-in', 'completed', 'Checking the stand-in')
    call('TaskUpdate', f'tu{ids[0]}b', {'taskId': str(ids[0]), 'status': 'completed'})
    result(f'tu{ids[0]}b', f'Updated task #{ids[0]} status')
    time.sleep(6)
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_tasks_end', 'role': 'assistant', 'stop_reason': 'end_turn',
        'usage': {'output_tokens': 30},
        'content': [{'type': 'text', 'text': 'Tasks played'}]}})
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 30000,
            'timestamp': now()})
    listed_as('idle')
    sys.stdout.write('Tasks played\n')


sub_dir = os.path.join(os.path.dirname(transcript), session, 'subagents')


def sub_agent(file, tool_use_id, description, lines):
    """A sub-agent as 2.1.300 files it: agent-<id>.meta.json naming the tool_use
    that started it, and agent-<id>.jsonl, every line isSidechain."""
    os.makedirs(sub_dir, exist_ok=True)
    with open(os.path.join(sub_dir, file + '.meta.json'), 'w') as f:
        json.dump({'agentType': 'Explore', 'description': description,
                   'toolUseId': tool_use_id, 'spawnDepth': 1}, f)
    with open(os.path.join(sub_dir, file + '.jsonl'), 'a') as f:
        for event in lines:
            event.update({'isSidechain': True, 'agentId': file,
                          'timestamp': now()})
            f.write(json.dumps(event) + '\n')


def say(text, mid):
    return {'type': 'assistant', 'message': {
        'id': mid, 'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}}


def agents_turn(text):
    """A line starting `agents:` plays a turn that starts a sub-agent with the
    Agent tool, which starts one of its own: both write their files under
    <session>/subagents, the first says "Surveying the repo", writes more four
    seconds on, and the turn ends after ten."""
    listed_as('busy')
    record({'type': 'user', 'timestamp': now(),
            'message': {'role': 'user', 'content': text}})
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_agent', 'role': 'assistant', 'stop_reason': 'tool_use',
        'usage': {'output_tokens': 20},
        'content': [{'type': 'tool_use', 'id': 'toolu_e2e_agent', 'name': 'Agent',
                     'input': {'description': 'survey the repo',
                               'subagent_type': 'Explore', 'prompt': 'p'}}]}})
    sub_agent('agent-e2esurvey', 'toolu_e2e_agent', 'survey the repo', [
        {'type': 'user', 'message': {'role': 'user', 'content': 'survey it for me'}},
        {'type': 'assistant', 'message': {
            'id': 'sa1', 'role': 'assistant', 'stop_reason': 'tool_use', 'content': [
                {'type': 'tool_use', 'id': 'toolu_e2e_nested', 'name': 'Agent',
                 'input': {'description': 'dig deeper', 'prompt': 'p'}}]}},
        say('Surveying the repo', 'sa2'),
    ])
    sub_agent('agent-e2edeeper', 'toolu_e2e_nested', 'dig deeper', [
        say('Digging in the nested one', 'sb1'),
    ])
    time.sleep(4)
    sub_agent('agent-e2esurvey', 'toolu_e2e_agent', 'survey the repo', [
        say('Found it, all done here', 'sa3'),
    ])
    time.sleep(6)
    record({'type': 'user', 'timestamp': now(), 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_e2e_agent', 'content': 'survey done'}]}})
    record({'type': 'assistant', 'timestamp': now(), 'message': {
        'id': 'msg_e2e_agents_end', 'role': 'assistant', 'stop_reason': 'end_turn',
        'usage': {'output_tokens': 30},
        'content': [{'type': 'text', 'text': 'Agents played'}]}})
    record({'type': 'system', 'subtype': 'turn_duration', 'durationMs': 11000,
            'timestamp': now()})
    listed_as('idle')
    sys.stdout.write('Agents played\n')


def prompt():
    sys.stdout.write('❯ ')
    sys.stdout.flush()


prompt()
while True:
    line = sys.stdin.readline()
    if not line:
        break
    text = line.rstrip('\n')
    if text.startswith('slow:'):
        slow_turn(text)
    elif text.startswith('agents:'):
        agents_turn(text)
    elif text.startswith('tasks:'):
        task_turn(text)
    elif text.startswith('wait:'):
        waiting_turn(text)
    elif text.startswith('long:'):
        long_turn(text)
    elif text.startswith('/'):
        name, _, args = text[1:].partition(' ')
        record({'type': 'system', 'subtype': 'local_command', 'content':
                f'<command-name>/{name}</command-name>\n'
                f'<command-message>{name}</command-message>\n'
                f'<command-args>{args.strip()}</command-args>'})
        printed = f'Context Usage: 12k/200k tokens (6%) from /{name}'
        record({'type': 'system', 'subtype': 'local_command', 'content':
                f'<local-command-stdout>{printed}</local-command-stdout>'})
        sys.stdout.write(printed + '\n')
    elif text:
        record({'type': 'user', 'message': {'role': 'user', 'content': text}})
        answer = f'Echo: {text}'
        record({'type': 'assistant', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': answer}]}})
        sys.stdout.write(answer + '\n')
    prompt()
