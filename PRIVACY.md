# Privacy and repository data policy

Voice Clone Studio processes sensitive biometric-like voice material. The repository must contain source code and generic documentation only.

## Never commit

- voice references, recordings, generated audio, transcripts, or saved voice profiles;
- voice or delivery presets created for a real person;
- model weights, caches, or packaged runtimes;
- `.env` files, tokens, credentials, signing certificates, private keys, or provisioning profiles;
- absolute personal machine paths, personal names, private email addresses, device names, or account identifiers;
- application output, logs, lock files, or diagnostic captures.

Runtime voice data is stored only in ignored local output directories and the user's Application Support directory.

## Before committing

Run:

```bash
python3 scripts/privacy_check.py
```

The GitHub Actions workflow runs the same check for every push and pull request.

## Incident response

If a secret or private voice artifact is ever committed, removing the file in a later commit is not sufficient. Rotate exposed credentials when applicable, rewrite the reachable Git history, force-push the sanitized history, and contact the hosting provider if cached objects require removal.
