# S3 EventBridge Transcribe SSM Flows

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Tests whether an MP4 uploaded to S3 can reach a Confluence page, with its transcript and S3 metadata, using only EventBridge, SSM Automation and Amazon Transcribe. There is no Lambda.

```sh
make test
make deploy
make e2e
make destroy
```

## Notes

- goal; simplest possible model for transcribing audio files
- overall pretty solid
- covers the core flows needed for a real development implementation
- nothing particularly notable beyond that; straightforward successful test
