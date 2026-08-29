test:
	python3 -m unittest tests/test_confluence_probe.py
	for t in event-patterns publication-adapter confluence-publication object-readiness readiness-reconciliation transcription-automation; do bash tests/test-$$t.sh || exit 1; done
