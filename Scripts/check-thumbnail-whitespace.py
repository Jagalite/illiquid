#!/usr/bin/env python3
"""Check the event's branch delta, never the synthetic PR merge's delta."""
import json
import os
import re
import subprocess


def git(*args):
    return subprocess.check_output(['git', *args], text=True, timeout=60).strip()


def commit(value):
    if not re.fullmatch(r'[0-9a-f]{40}', value):
        raise ValueError('Expected a full event commit SHA')
    return git('rev-parse', '--verify', value + '^{commit}')


def boundary(event_name, event, sha):
    if event_name == 'pull_request':
        pr = event['pull_request']
        base, head = commit(pr['base']['sha']), commit(pr['head']['sha'])
    elif event_name in ('push', 'workflow_dispatch'):
        head = commit(event['after'] if event_name == 'push' else sha)
        branch = event['repository']['default_branch']
        git('check-ref-format', 'refs/heads/' + branch)
        base = git('rev-parse', '--verify', 'refs/remotes/origin/' + branch + '^{commit}')
        if base == head:
            raise ValueError('Default-branch runs have no PR boundary; run on the topic branch')
    else:
        raise ValueError('Unsupported event: ' + event_name)
    ancestor = git('merge-base', base, head)
    print(json.dumps(dict(event=event_name, checkout=git('rev-parse', 'HEAD'),
                          base=base, head=head, merge_base=ancestor)), flush=True)
    return ancestor, head


def main():
    with open(os.environ['GITHUB_EVENT_PATH']) as source:
        event = json.load(source)
    base, head = boundary(os.environ['GITHUB_EVENT_NAME'], event, os.environ['GITHUB_SHA'])
    # Preserve original stack qualification independently of evolving main history.
    start = '8637a8d2c6a628699d5a552a55061b4e0bfc6f10'
    end = '70a5c96f41295a2edac27801a4d484a86d623784'
    for required in (end, '8e51176463b873cca080d92d9c4854a1d078be35'):
        git('merge-base', '--is-ancestor', required, head)
    for left, right in ((start, end), (base, head)):
        print('Checking whitespace:', left, right, flush=True)
        subprocess.run(['git', 'diff', '--check', left, right], check=True, timeout=60)


if __name__ == '__main__':
    main()
