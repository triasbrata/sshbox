#!/usr/bin/env python3
"""The e2e stand-in for chat's own `claude -p --input-format stream-json
--output-format stream-json --permission-prompt-tool stdio`, as far as
AskUserQuestion goes (.maestro/chat_ask.yaml, tools/e2e_android.sh's chat_ask).

tools/e2e_android.sh puts this at ~/.e2e-ask.py, and its claude stand-in runs
it for `-p` where it is. It speaks what a real 2.1.287 was measured to:

  * a user message  -> an assistant `tool_use` named AskUserQuestion and the
    CLI's `control_request` (can_use_tool) for it, whose answer it then waits
    for on stdin: the first message asks which colour, the second which size;
  * `control_response` allow -> the tool's result, with the answers it was
    given in `tool_use_result`, and a reply saying what was chosen, which is
    what a flow can read off the screen;
  * `control_response` deny -> the result as the error it is, and a reply
    saying it was dismissed;
  * the SDK's `initialize` -> ~/.e2e-commands.json where a flow left one, as
    the plain stand-in answers it.

Every control_response it gets is kept, whole, a line each, in
~/.e2e-ask-replies.jsonl, so the run can check what the app really sent.
"""
import json
import os
import sys

HOME = os.environ['HOME']
REPLIES = os.path.join(HOME, '.e2e-ask-replies.jsonl')

ASKS = [
    {
        'tool_use_id': 'toolu_e2e_ask1',
        'request_id': 'req-ask-1',
        'questions': [{
            'question': 'Which colour?',
            'header': 'Colour',
            'multiSelect': False,
            'options': [
                {'label': 'Red', 'description': 'A warm colour.'},
                {'label': 'Blue', 'description': 'A cool colour.'},
            ],
        }],
    },
    {
        'tool_use_id': 'toolu_e2e_ask2',
        'request_id': 'req-ask-2',
        'questions': [{
            'question': 'Which size?',
            'header': 'Size',
            'multiSelect': False,
            'options': [
                {'label': 'Small', 'description': 'A small size.'},
                {'label': 'Large', 'description': 'A large size.'},
            ],
        }],
    },
]


def out(event):
    sys.stdout.write(json.dumps(event) + '\n')
    sys.stdout.flush()


def assistant(*blocks):
    out({'type': 'assistant', 'message': {'role': 'assistant', 'content': list(blocks)}})


def finish(text):
    assistant({'type': 'text', 'text': text})
    out({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': text})


asked = 0
pending = {}
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        message = json.loads(raw)
    except ValueError:
        continue
    kind = message.get('type')
    request = message.get('request') or {}
    if kind == 'control_request' and request.get('subtype') == 'initialize':
        try:
            sys.stdout.write(open(os.path.join(HOME, '.e2e-commands.json')).read())
            sys.stdout.flush()
        except OSError:
            pass
    elif kind == 'user':
        if asked >= len(ASKS):
            finish('Nothing more to ask.')
            continue
        ask = ASKS[asked]
        asked += 1
        pending[ask['request_id']] = ask
        tool_input = {'questions': ask['questions']}
        assistant({'type': 'tool_use', 'id': ask['tool_use_id'],
                   'name': 'AskUserQuestion', 'input': tool_input})
        out({'type': 'control_request', 'request_id': ask['request_id'],
             'request': {'subtype': 'can_use_tool', 'tool_name': 'AskUserQuestion',
                         'display_name': 'AskUserQuestion', 'input': tool_input,
                         'tool_use_id': ask['tool_use_id'],
                         'requires_user_interaction': True}})
    elif kind == 'control_response':
        with open(REPLIES, 'a') as kept:
            kept.write(raw + '\n')
        response = message.get('response') or {}
        ask = pending.pop(response.get('request_id'), None)
        if ask is None:
            continue
        decision = response.get('response') or {}
        question = ask['questions'][0]['question']
        if decision.get('behavior') == 'allow':
            answers = (decision.get('updatedInput') or {}).get('answers') or {}
            answer = answers.get(question)
            out({'type': 'user',
                 'message': {'role': 'user', 'content': [{
                     'type': 'tool_result', 'tool_use_id': ask['tool_use_id'],
                     'content': 'The user answered: "%s"="%s".' % (question, answer)}]},
                 'tool_use_result': {'questions': ask['questions'], 'answers': answers}})
            finish('You chose %s' % answer if answer else 'You chose nothing')
        else:
            note = decision.get('message') or 'dismissed'
            out({'type': 'user',
                 'message': {'role': 'user', 'content': [{
                     'type': 'tool_result', 'tool_use_id': ask['tool_use_id'],
                     'content': note, 'is_error': True}]},
                 'tool_use_result': 'Error: ' + note})
            finish('You dismissed the question')
