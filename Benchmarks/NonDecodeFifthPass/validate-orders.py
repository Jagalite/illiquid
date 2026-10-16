#!/usr/bin/env python3
"""Verify actual recorded process order, including rejection of the earlier two-variant bug."""
import argparse, collections, json, pathlib

def validate(rows, variants):
    groups = collections.defaultdict(list)
    identities = set()
    for row in rows:
        key = (row['workload'], row['size'], row['repeat'])
        identity = (*key, row['variant'])
        if identity in identities:
            raise ValueError(f'duplicate observation {identity}')
        identities.add(identity)
        groups[key].append(row)
    for key, values in groups.items():
        repeat = key[2]
        if len(variants) == 2:
            expected = variants if repeat % 2 == 0 else list(reversed(variants))
        else:
            expected = variants[repeat % len(variants):] + variants[:repeat % len(variants)]
            if (repeat // len(variants)) % 2:
                expected = list(reversed(expected))
        actual = [value['variant'] for value in values]
        if actual != expected:
            raise ValueError(f'order mismatch {key}: {actual}, expected {expected}')
        for index, value in enumerate(values):
            if 'process_order' in value and value['process_order'] != index:
                raise ValueError(f'order metadata mismatch {key}')
    if not groups:
        raise ValueError('empty evidence')
    return {'observations': len(rows), 'complete_rounds': len(groups), 'passed': True}

def self_test():
    def rows(order, repeat):
        return [{'workload':'probe','size':1,'repeat':repeat,'variant':v,'process_order':i}
                for i,v in enumerate(order)]
    validate(rows(['A','B'],0) + rows(['B','A'],1),['A','B'])
    try:
        validate(rows(['A','B'],0) + rows(['A','B'],1),['A','B'])
    except ValueError:
        pass
    else:
        raise AssertionError('failed to reject original two-variant ordering bug')
    try:
        validate(rows(['A','B'],0) + rows(['A','B'],0),['A','B'])
    except ValueError:
        pass
    else:
        raise AssertionError('failed to reject duplicated observations')
    return 3

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('output',type=pathlib.Path)
    args=p.parse_args()
    env=json.loads((args.output/'environment.json').read_text())
    rows=[json.loads(x) for x in (args.output/'measurements.jsonl').read_text().splitlines()]
    result=validate(rows,env['variants']); result['self_tests']=self_test()
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
