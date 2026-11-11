# Changelog

## [0.1.2](https://github.com/bitwise-media-group/auto-dj/compare/v0.1.1...v0.1.2) (2026-11-11)


### Features

* **db:** read play histories and tags, create playlists with masterPlaylists6.xml ([6ba9a2c](https://github.com/bitwise-media-group/auto-dj/commit/6ba9a2cc7fd588b1297cbdc1498fe1e5496fca92))
* **features:** stream a long recording's frame features and cache them ([5ed55e3](https://github.com/bitwise-media-group/auto-dj/commit/5ed55e3f4a5aaf874618c29f00f1da8004ed7123))
* **recording:** split a set recording into tagged AAC tracks by its play history ([f4942bf](https://github.com/bitwise-media-group/auto-dj/commit/f4942bfbcb20a0357ea298617f3a2785c40005db))
* **set:** build sets from intelligent playlists ([58a930c](https://github.com/bitwise-media-group/auto-dj/commit/58a930cf8a1eecfa94eb2958b6e6cd0e62ec5306))


### Bug Fixes

* **deps:** bump go to 1.27.4 ([dd4f721](https://github.com/bitwise-media-group/auto-dj/commit/dd4f721dc9092318c0d2b8ceb06fe1411a17344b))
* **deps:** update bitwise-media-group/github-workflows action to v8.1.1 ([#14](https://github.com/bitwise-media-group/auto-dj/issues/14)) ([6bac19c](https://github.com/bitwise-media-group/auto-dj/commit/6bac19ca0e12f1f58769c476a7d2c32365388551))
* **deps:** update module modernc.org/sqlite to v1.61.0 ([#7](https://github.com/bitwise-media-group/auto-dj/issues/7)) ([fa6561d](https://github.com/bitwise-media-group/auto-dj/commit/fa6561d311a231a3c7bd5098aa1e4f1873b5ad8d))
* **deps:** update module modernc.org/sqlite to v1.61.1 ([#13](https://github.com/bitwise-media-group/auto-dj/issues/13)) ([04e213f](https://github.com/bitwise-media-group/auto-dj/commit/04e213f639498eb79a6d53af1837d615dedd16e7))
* **deps:** update module modernc.org/sqlite to v1.62.0 ([#20](https://github.com/bitwise-media-group/auto-dj/issues/20)) ([200c535](https://github.com/bitwise-media-group/auto-dj/commit/200c535174771cbba7663d00cd972e57c79576f5))
* **release:** pass mise trust through to the goreleaser sbom commands ([fbfb41f](https://github.com/bitwise-media-group/auto-dj/commit/fbfb41fcb415212e64f53a929285f84e6883ff2c))

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
