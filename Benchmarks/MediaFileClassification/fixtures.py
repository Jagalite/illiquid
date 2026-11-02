from pathlib import Path


def touch(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(exist_ok=False)


def fixtures(root: Path):
    root.mkdir(parents=True)
    cases = []
    for name, media, subtitles, unrelated, upper in [
        ('empty', 0, 0, 0, False), ('small', 3, 3, 0, False),
        ('media250', 250, 0, 0, False), ('mixed', 25, 25, 5000, False),
        ('unsupported5000', 0, 0, 5000, False), ('subtitle-heavy', 25, 1000, 0, False),
        ('uppercase-mixed', 25, 25, 5000, True),
    ]:
        folder = root / name
        folder.mkdir()
        for i in range(media): touch(folder / f'Feature {i:04d}.{"MKV" if upper else "mkv"}')
        for i in range(subtitles): touch(folder / f'Feature {i:04d}.en.{"SRT" if upper else "srt"}')
        for i in range(unrelated): touch(folder / f'notes-{i:05d}.{"TXT" if upper else "txt"}')
        cases.append({'id': name, 'path': str(folder), 'expected_media': media,
                      'entries': media + subtitles + unrelated})

    folder = root / 'unicode-extensions'
    folder.mkdir()
    extensions = ['mKv', 'MKV', 'İDX', 'ıdx', 'ſrt', 'ＭＫＶ', 'mkv\u0301', 'mkv', 'MKV', 'ass', 'srt', 'idx', 'webm']
    for i in range(520):
        touch(folder / f'Épisode 日本語 {i:04d}.{extensions[i % len(extensions)]}')
    cases.append({'id': 'unicode-extensions', 'path': str(folder), 'expected_media': None, 'entries': 520})

    folder = root / 'unicode-names-ascii-extensions'
    folder.mkdir()
    for i in range(250):
        touch(folder / f'Épisode 日本語 🐈 {i:04d}.mkv')
        touch(folder / f'Épisode 日本語 🐈 {i:04d}.en.srt')
    cases.append({'id': 'unicode-names-ascii-extensions', 'path': str(folder), 'expected_media': 250, 'entries': 500})

    folder = root / 'symlink-rich'
    target = root / 'targets'
    folder.mkdir()
    target.mkdir()
    for i in range(100):
        for extension in ('mkv', 'srt', 'txt'):
            actual = target / f'Feature {i:04d}.{extension}'
            touch(actual)
            (folder / f'alias-{i:04d}-{extension}').symlink_to(actual)
    (folder / 'broken').symlink_to(target / 'missing.mkv')
    (folder / 'directory.mkv').symlink_to(target, target_is_directory=True)
    touch(target / '.Hidden.mkv')
    (folder / '.hidden-alias').symlink_to(target / '.Hidden.mkv')
    cases.append({'id': 'symlink-rich', 'path': str(folder), 'expected_media': 100, 'entries': 303})

    folder = root / 'filename-edge-controls'
    folder.mkdir()
    for name in ['.hidden.mp4', '.mkv', 'no-extension', 'trailing.', 'many.dots.mkv', 'movie.mkv.txt',
                 'percent%2Emp4', 'literal?query.mp4', 'literal#fragment.webm', 'space .mkv', 'unsupported.sup']:
        touch(folder / name)
    (folder / 'directory.mkv').mkdir()
    touch(folder / 'directory.mkv/nested.mp4')
    cases.append({'id': 'filename-edge-controls', 'path': str(folder), 'expected_media': 4, 'entries': 12})
    return cases
