# Changelog

## [0.1.2](https://github.com/bitwise-media-group/auto-dj/compare/v0.1.1...v0.1.2) (2026-11-01)


### Bug Fixes

* **deps:** update module modernc.org/sqlite to v1.61.0 ([#7](https://github.com/bitwise-media-group/auto-dj/issues/7)) ([fa6561d](https://github.com/bitwise-media-group/auto-dj/commit/fa6561d311a231a3c7bd5098aa1e4f1873b5ad8d))

## [0.1.1](https://github.com/bitwise-media-group/auto-dj/compare/v0.1.0...v0.1.1) (2026-10-31)


### Bug Fixes

* **deps:** update the toolchain submodule to v3.4.0 ([690585e](https://github.com/bitwise-media-group/auto-dj/commit/690585eacd4ab062be4958f3ccf1ac3ff96f3538))

## 0.1.0 (2026-10-31)


### ⚠ BREAKING CHANGES

* the binary is now auto-dj, the ADJ_* environment variables are AUTO_DJ_*, and the default work dir moved from ~/.cache/adj to ~/.cache/auto-dj (move the old cache to keep the decoded features).
* the CLI is adj instead of rekordbox-cue; ADJ_WORK, ADJ_PATH_MAP and ADJ_CLOUD_DIR replace the REKORDBOX_CUE_* variables; the work dir moves to ~/.cache/adj and the feature cache to .f32.gz files, so run adj features once. _cue_work (backups, ledger, transition cache) is unchanged.

### Features

* port rekordbox-cue to Go as adj ([a248549](https://github.com/bitwise-media-group/auto-dj/commit/a248549d3d831c2cb41c53b51a23eabc51e3da30))
* rename to auto-dj and add the generated demo set ([c1d98c6](https://github.com/bitwise-media-group/auto-dj/commit/c1d98c636bbca15268529ef69b8e84b66b2f80d6))
* **set:** play set previews at a fixed tempo, 128 BPM by default ([6205829](https://github.com/bitwise-media-group/auto-dj/commit/62058295b6557128c2e0be372b2df99131f86ae8))
