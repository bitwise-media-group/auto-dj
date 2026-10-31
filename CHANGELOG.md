# Changelog

## 0.1.0 (2026-10-31)


### ⚠ BREAKING CHANGES

* the binary is now auto-dj, the ADJ_* environment variables are AUTO_DJ_*, and the default work dir moved from ~/.cache/adj to ~/.cache/auto-dj (move the old cache to keep the decoded features).
* the CLI is adj instead of rekordbox-cue; ADJ_WORK, ADJ_PATH_MAP and ADJ_CLOUD_DIR replace the REKORDBOX_CUE_* variables; the work dir moves to ~/.cache/adj and the feature cache to .f32.gz files, so run adj features once. _cue_work (backups, ledger, transition cache) is unchanged.

### Features

* port rekordbox-cue to Go as adj ([a248549](https://github.com/bitwise-media-group/auto-dj/commit/a248549d3d831c2cb41c53b51a23eabc51e3da30))
* rename to auto-dj and add the generated demo set ([c1d98c6](https://github.com/bitwise-media-group/auto-dj/commit/c1d98c636bbca15268529ef69b8e84b66b2f80d6))
* **set:** play set previews at a fixed tempo, 128 BPM by default ([6205829](https://github.com/bitwise-media-group/auto-dj/commit/62058295b6557128c2e0be372b2df99131f86ae8))
