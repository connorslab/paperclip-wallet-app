#!/usr/bin/env python3
"""Sign immutable local candidates; this command does not publish or certify acceptance."""
import argparse
import hashlib
import json
import os
import ssl
from pathlib import Path
import subprocess
import tempfile


def run(arguments, **kwargs):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{Path(arguments[0]).name} failed. No release was published.')
    return result.stdout


def certificate_der(data):
    """Compare certificate identities independently of checkout line endings."""
    return ssl.PEM_cert_to_DER_cert(data.decode('ascii').strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--aab', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--signing-home', type=Path, default=Path.home() / 'Library/Application Support/Paperclip Release Signing')
    parser.add_argument('--sdk', required=True, type=Path)
    parser.add_argument('--java-home', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    os.environ['JAVA_HOME'] = str(args.java_home.resolve(strict=True))
    if args.output.exists():
        raise RuntimeError('Choose a new candidate directory; never replace signed artifacts.')
    source = Path(__file__).resolve().parent
    tools = args.sdk / 'build-tools/36.0.0'
    # Check identity before producing any signed file. Private keys remain local.
    for account in ('android-app', 'android-upload'):
        if certificate_der((args.signing_home / (account + '.pem')).read_bytes()) != certificate_der((source / (account + '.pem')).read_bytes()):
            raise RuntimeError('Signing certificate differs from the reviewed release identity.')
    args.output.mkdir(parents=True, mode=0o700)
    results = {}
    with tempfile.TemporaryDirectory(prefix='.sign-', dir=args.signing_home) as temporary:
        temp = Path(temporary)
        for kind, account, alias, input_file in [('apk', 'android-app', 'paperclip-app', args.apk), ('aab', 'android-upload', 'paperclip-upload', args.aab)]:
            secret = run([args.signing_home / 'keychain-helper', 'read', account])
            password_file = temp / (account + '.password')
            password_file.write_bytes(secret)
            keyfile = args.signing_home / (account + '.p12')
            certificate = run([args.java_home / 'bin/keytool', '-exportcert', '-rfc', '-alias', alias, '-keystore', keyfile, '-storepass:file', password_file])
            if certificate_der(certificate) != certificate_der((source / (account + '.pem')).read_bytes()):
                raise RuntimeError('Private keystore does not match the reviewed public certificate.')
            output = args.output / ('Paperclip.' + kind)
            if kind == 'apk':
                aligned = temp / 'aligned.apk'
                run([tools / 'zipalign', '-P', '16', '-f', '4', input_file, aligned])
                # The PKCS12 key uses the store password. Passing the same file
                # again as --key-pass makes apksigner read past its first line.
                run([tools / 'apksigner', 'sign', '--ks', keyfile, '--ks-key-alias', alias, '--ks-pass', 'file:' + str(password_file), '--out', output, aligned])
                result = run([tools / 'apksigner', 'verify', '--verbose', '--print-certs', output])
                run([tools / 'zipalign', '-c', '-P', '16', '4', output])
            else:
                run([args.java_home / 'bin/jarsigner', '-keystore', keyfile, '-storepass:file', password_file, '-keypass:file', password_file, '-sigalg', 'SHA256withRSA', '-digestalg', 'SHA-256', '-signedjar', output, input_file, alias])
                result = run([args.java_home / 'bin/jarsigner', '-verify', output])
                if b'jar verified.' not in result:
                    raise RuntimeError('Bundle signature verification did not succeed.')
            (args.output / (kind + '-signature.txt')).write_bytes(result)
            results[output.name] = hashlib.sha256(output.read_bytes()).hexdigest()
            password_file.unlink()
        (args.output / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in results.items()))
        fingerprint = json.loads((args.signing_home / 'identity.json').read_text())['linux_fingerprint']
        expected = 'EA034CC6E0E048811266E8E9D95A43AAA5171575'
        if fingerprint != expected:
            raise RuntimeError('Release manifest signer changed.')
        password = run([args.signing_home / 'keychain-helper', 'read', 'linux-release'])
        run(['gpg', '--homedir', args.signing_home / 'gnupg', '--batch', '--no-tty', '--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--local-user', fingerprint, '--armor', '--detach-sign', args.output / 'SHA256SUMS'], input=password + b'\n')
        # GnuPG checks a Unix socket path even with --no-autostart. Keep this
        # public-only verification directory short on macOS.
        with tempfile.TemporaryDirectory(prefix='pc-verify-', dir='/tmp') as verify:
            run(['gpg', '--homedir', verify, '--batch', '--no-autostart', '--import', source / 'linux-release-public.asc'])
            run(['gpg', '--homedir', verify, '--batch', '--no-autostart', '--verify', args.output / 'SHA256SUMS.asc', args.output / 'SHA256SUMS'])
    print('APK, upload bundle and release manifest signatures verified. Candidates are not published.')


if __name__ == '__main__':
    main()
