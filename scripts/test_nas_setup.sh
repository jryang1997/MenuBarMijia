#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

root = Path.cwd()
failures = []

def check(condition, message):
    print(('PASS ' if condition else 'FAIL ') + message)
    if not condition:
        failures.append(message)

with tempfile.TemporaryDirectory(prefix='menumijia-nas-test-') as temporary:
    task = Path(temporary)
    nas = task / 'nas'
    shutil.copytree(root / 'nas', nas, ignore=shutil.ignore_patterns('components'))
    components = nas / 'components'
    components.mkdir()
    bin_dir = task / 'bin'
    bin_dir.mkdir()
    log = task / 'calls.log'
    log.touch()
    (bin_dir / 'ssh').write_text('#!/bin/bash\necho "ssh $*" >> "$NAS_TEST_LOG"\nexit 91\n')
    (bin_dir / 'curl').write_text('#!/bin/bash\necho "curl $*" >> "$NAS_TEST_LOG"\n[ "${NAS_TEST_READY:-0}" = 1 ] && { echo 200; exit 0; }\nexit 92\n')
    (bin_dir / 'docker').write_text('''#!/bin/bash
printf 'docker %s\\n' "$*" >> "$NAS_TEST_LOG"
case "$1" in
    info) exit 0 ;;
    pull) [ "${NAS_TEST_PULL:-fail}" = success ] ;;
    inspect) echo "${NAS_TEST_VERSION:-wrong-version}" ;;
    ps) [ "${NAS_TEST_OLD:-1}" = 1 ] || exit 0; echo 'homeassistant|homeassistant/home-assistant|Up|other' ;;
    tag) [ "${NAS_TEST_TAG_FAIL:-0}" = 0 ] ;;
    rm) [ "${NAS_TEST_OLD:-1}" = 1 ] ;;
    *) exit 0 ;;
esac
''')
    (bin_dir / 'uname').write_text('#!/bin/bash\necho x86_64\n')
    (bin_dir / 'ip').write_text('#!/bin/bash\necho "local src 192.0.2.10"\n')
    for path in bin_dir.iterdir():
        path.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
               NAS_TEST_LOG=str(log), PACKAGE_ONLY='1', TMPDIR=str(task))
    for key in ('GH_PROXY', 'MIRROR_FALLBACK', 'FORCE_NEW', 'HA_VERSION',
                'HA_IMAGE_DIGEST', 'COMPONENTS_SHA256'):
        env.pop(key, None)

    for component in ('xiaomi_home', 'midea_ac_lan'):
        with zipfile.ZipFile(components / (component + '.zip'), 'w') as archive:
            archive.writestr('manifest.json', '{"version":"test"}')

    def deploy():
        log.write_text('')
        return subprocess.run(['bash', str(nas / 'deploy_ha.sh')], env=env,
                              capture_output=True, text=True, errors='replace', timeout=10)

    result = deploy()
    check(result.returncode != 0 and 'SHA256' in result.stdout,
          'local ZIP without a checksum is rejected')
    check(not log.read_text(), 'a missing ZIP checksum never reaches network commands')

    for archive in components.glob('*.zip'):
        Path(str(archive) + '.sha256').write_text('not-a-sha256\n')
    result = deploy()
    check(result.returncode != 0 and not log.read_text(), 'malformed checksums fail before network access')

    for archive in components.glob('*.zip'):
        Path(str(archive) + '.sha256').write_text('0' * 64 + '\n')
    result = deploy()
    check(result.returncode != 0 and not log.read_text(), 'mismatched ZIP checksums fail before network access')

    for archive in components.glob('*.zip'):
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        Path(str(archive) + '.sha256').write_text(digest + '  ' + archive.name + '\n')
    result = deploy()
    check(result.returncode == 0, 'verified local ZIPs produce a package')
    output = next((line.split('已生成 ', 1)[1] for line in result.stdout.splitlines()
                   if '已生成 ' in line), None)
    check(output is not None, 'successful packaging reports the generated archive path')
    if output:
        with tarfile.open(output) as archive:
            check({'xiaomi_home/manifest.json', 'midea_ac_lan/manifest.json'} <= set(archive.getnames()),
                  'the generated package contains both integrations')
        shutil.rmtree(Path(output).parent)

    (bin_dir / 'ssh').write_text('''#!/bin/bash
printf 'ssh %s\\n' "$*" >> "$NAS_TEST_LOG"
case "$*" in
    *'d=$(mktemp -d /tmp/ha_setup.'*) echo /tmp/ha_setup.TEST ;;
    *'cat > '*) cat >/dev/null ;;
    *'sudo FORCE_NEW='*) exit 37 ;;
esac
''')
    log.write_text('')
    result = subprocess.run(['bash', str(nas / 'deploy_ha.sh')],
                            env=dict(env, PACKAGE_ONLY='0', MIRROR_FALLBACK='1', NAS_IP='nas.invalid'),
                            input='tester\n', capture_output=True, text=True, errors='replace', timeout=10)
    calls = log.read_text()
    check('MIRROR_FALLBACK=1' in calls and 'COMPONENTS_SHA256=' in calls,
          'deployment passes mirror consent and the package digest to the remote command')
    check(result.returncode == 37, 'deployment preserves a remote failure exit status')

    for archive in components.glob('*.zip'):
        component = archive.stem
        archive.unlink()
        with tarfile.open(components / (component + '.tar.gz'), 'w:gz') as tar:
            payload = b'{"version":"test"}'
            info = tarfile.TarInfo(component + '/manifest.json')
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
    result = deploy()
    check(result.returncode != 0 and not log.read_text(), 'local tar archives also require checksums')
    for archive in components.glob('*.tar.gz'):
        Path(str(archive) + '.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '\n')
    result = deploy()
    check(result.returncode == 0, 'verified local tar archives produce a package')

    work = task / 'remote-work'
    work.mkdir(mode=0o700)
    archive_path = work / 'components.tar.gz'
    with tarfile.open(archive_path, 'w:gz') as archive:
        for component in ('xiaomi_home', 'midea_ac_lan'):
            payload = b'{"version":"test"}'
            info = tarfile.TarInfo(component + '/manifest.json')
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
    volume = task / 'volume'
    volume.mkdir()
    remote_script = nas / 'remote_setup.sh'
    remote_script.write_text(remote_script.read_text().replace('/volume1 /volume2 /volume3', str(volume)))
    remote_env = dict(env, FORCE_NEW='1',
                      COMPONENTS_SHA256=hashlib.sha256(archive_path.read_bytes()).hexdigest())

    def remote(arguments, extra=None):
        log.write_text('')
        run_env = dict(remote_env, **(extra or {}))
        result = subprocess.run(['bash', str(nas / 'remote_setup.sh'), *arguments],
                                env=run_env, capture_output=True, text=True, errors='replace', timeout=10)
        return result, log.read_text()

    result, calls = remote([])
    check(result.returncode != 0 and not calls, 'missing remote work directory fails before Docker access')
    work.chmod(0o755)
    result, calls = remote([str(work)])
    check(result.returncode != 0 and not calls, 'a public remote work directory is rejected')
    work.chmod(0o700)
    result, calls = remote([str(work)], {'COMPONENTS_SHA256': '0' * 64})
    check(result.returncode != 0 and not calls, 'a corrupt remote package fails before Docker access')
    original = archive_path.read_bytes()
    archive_path.write_bytes(b'not a gzip archive')
    result, calls = remote([str(work)], {'COMPONENTS_SHA256': hashlib.sha256(archive_path.read_bytes()).hexdigest()})
    check(result.returncode != 0 and not calls, 'a malformed archive fails before touching Docker')
    archive_path.write_bytes(original)
    result, calls = remote([str(work)])
    check(result.returncode != 0 and 'docker pull ghcr.io/' in calls,
          'the default deployment tries the official image')
    check(not any('docker ' + command in calls for command in ('stop ', 'update ', 'rename ', 'rm ', 'run ', 'tag ')),
          'image download failure does not change an existing container or image tag')
    check('daocloud' not in calls and 'dockerproxy' not in calls,
          'default deployment never contacts a third-party mirror')
    result, calls = remote([str(work)], {'MIRROR_FALLBACK': '1'})
    pulls = [line for line in calls.splitlines() if line.startswith('docker pull ')]
    check(len(pulls) > 1 and pulls[0].startswith('docker pull ghcr.io/'),
          'explicit mirror fallback still tries the official image first')
    result, calls = remote([str(work)], {'NAS_TEST_PULL': 'success'})
    check(result.returncode != 0 and 'docker inspect -f {{index .Config.Labels' in calls and 'docker tag ' not in calls,
          'image version mismatch fails before changing the local image tag')

    result, calls = remote([str(work)], {'NAS_TEST_PULL': 'success', 'NAS_TEST_VERSION': '2026.10.4',
                                          'NAS_TEST_TAG_FAIL': '1'})
    check(result.returncode != 0 and 'docker stop ' not in calls,
          'local image tag failure does not stop an existing container')
    result, calls = remote([str(work)], {'FORCE_NEW': '0'})
    check(result.returncode == 2 and not any('docker ' + command in calls for command in
                                            ('pull ', 'stop ', 'update ', 'rename ', 'rm ', 'run ', 'tag ')),
          'an existing installation without FORCE_NEW is left untouched')
    result, calls = remote([str(work)], {'NAS_TEST_PULL': 'success', 'NAS_TEST_VERSION': '2026.10.4',
                                          'NAS_TEST_READY': '1', 'NAS_TEST_OLD': '0'})
    installed = volume / 'docker/homeassistant/config/custom_components'
    check(result.returncode == 0 and 'docker run -d' in calls and '已就绪' in result.stdout,
          'verified deployment starts the container and observes readiness')
    check(all((installed / component / 'manifest.json').is_file()
              for component in ('xiaomi_home', 'midea_ac_lan')),
          'successful deployment installs both verified integrations')

if failures:
    raise SystemExit(str(len(failures)) + ' NAS safety checks failed')
PY
