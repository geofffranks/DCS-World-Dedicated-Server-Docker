# Fancyindex theme provenance and license

The two HTML files in this directory are the nginx fancyindex header/footer
theme that the LinuxServer.io webtop images historically served for the
desktop file-manager (`/files`). The current upstream webtop base no longer
ships them, so this project vendors them to preserve the feature.

## Source

- Upstream project: <https://github.com/selkies-project/selkies>
- Path: `addons/selkies-web-core/nginx/header.html` and
  `addons/selkies-web-core/nginx/footer.html`
- Exact revision vendored: commit
  `348bc4f61da66198573e7e57db9a266aca1991d5` on the `lsio` branch — the
  revision pinned by `linuxserver/docker-baseimage-selkies` for the
  `webtop:debian-xfce` image this project builds on.
- Retrieval chain: the files were read out of the production
  `dcs-world-dedicated-server` container (baked into the webtop base image),
  then byte-verified against the pinned upstream revision:
  - `header.html` md5 `07df04cfea7a886caabac5829d7d5c3d` — identical to the
    pinned upstream file (7789 bytes).
  - `footer.html` md5 `7ef247a808270487e193f306ffa280c0` — identical to the
    pinned upstream file (2153 bytes). The copy that ships inside the older
    production image differs only in that the image's `init-nginx` script had
    already substituted its `REPLACE_DOWNLOADS_PATH` placeholder; the vendored
    file keeps the upstream placeholder form and the substitution is applied
    at install time (see below).
- The files were removed from upstream selkies in commit
  `fbcb1703355def2c00255a4da1e3fafe93b4d8d9` (2026-06-20, web-core refactor),
  which is why current webtop bases no longer include the theme.

## License

These files are distributed under the Mozilla Public License, version 2.0
(the license of the selkies-project/selkies repository at the pinned
revision; see <https://github.com/selkies-project/selkies/blob/348bc4f61da66198573e7e57db9a266aca1991d5/LICENSE>).

MPL-2.0 is file-level copyleft: the covered files stay under MPL-2.0, their
source is provided here in full, and the rest of this project (GPL-3, see the
repository `LICENSE`) remains under its own license as permitted by MPL-2.0
section 3.3/3.4. Upstream copyright remains with the Selkies authors; the
footer retains its visible "© Selkies" notice.

## Install-time substitutions

The files are vendored byte-exact; both substitutions below are applied by
the container's `init-nginx-guard` service when it installs the theme into
the web root on each boot:

1. `REPLACE_DOWNLOADS_PATH` → the file-manager directory
   (`FILE_MANAGER_PATH`, default `/config/Desktop`). This mirrors the
   substitution the LinuxServer `init-nginx` script historically applied to
   the baked copy.
2. `const webPathPrefix = '/files/'` →
   `const webPathPrefix = '<SUBFOLDER>files/'`, where `<SUBFOLDER>` is the
   normalized `SUBFOLDER` environment value (default `/`). The upstream file
   hardcodes the root-relative path; the substitution keeps the footer's
   path-rewriting logic correct when the desktop is served under a subfolder.
