#
# DCS-World-Dedicated-Server-Docker Dockerfile.
# aterfax/dcs-world-dedicated-server
#

# Builder stage: resolve the nginx.org mainline package exactly once from the
# signed repository and compile the fancyindex module against the exact
# matching nginx source. None of these build tools or sources reach the
# runtime stage.
FROM debian:trixie-slim AS nginx-module-builder

ARG DEBIAN_FRONTEND=noninteractive

# Pinned aperezdc/ngx-fancyindex revision (v0.5.2, the series Debian trixie
# ships). The archive is fetched by commit SHA so the pin cannot drift.
ARG FANCYINDEX_REV=6cdffdb0af493b7c21eedba2f09d8486579f3922

# Earliest nginx mainline release this image accepts.
ARG NGINX_MIN_RELEASE=1.31.9

RUN set -eu; \
    . /etc/os-release; \
    test "$VERSION_CODENAME" = "trixie" || { \
        echo "builder base is ${VERSION_CODENAME:-unknown}, expected trixie" >&2; \
        exit 1; \
    }; \
    apt-get update -o APT::Update::Error-Mode=any \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gpg \
        gpg-agent \
        build-essential \
        libpcre2-dev \
        zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Fetch the nginx.org package signing keys and export ONLY the known nginx
# packaging primaries into the trusted keyring: keys are imported into a
# throwaway home, every known primary fingerprint must be present, and just
# those primaries are exported. A fetched bundle padded with unknown keys
# never reaches the trusted keyring, and a missing known key fails the build.
RUN set -eu; \
    KNOWN_FPRS='573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 8540A6F18833A80E9C1653A42FD21310B49F6B46 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3'; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        -o /tmp/nginx_signing.key https://nginx.org/keys/nginx_signing.key; \
    test -s /tmp/nginx_signing.key; \
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /tmp/nginx_signing.key; \
    GNUPGHOME="$(mktemp -d)"; \
    export GNUPGHOME; \
    gpg --import /tmp/nginx_signing.key; \
    for fpr in ${KNOWN_FPRS}; do \
        gpg --list-keys --with-colons | grep -q "^fpr:::::::::${fpr}:" || { \
            echo "known nginx packaging key ${fpr} missing from fetched key file" >&2; \
            exit 1; \
        }; \
    done; \
    gpg --export ${KNOWN_FPRS} > /usr/share/keyrings/nginx-archive-keyring.gpg; \
    rm -rf "${GNUPGHOME}"; \
    unset GNUPGHOME; \
    test -s /usr/share/keyrings/nginx-archive-keyring.gpg; \
    EXPORTED_FPRS="$(gpg --with-colons --show-keys /usr/share/keyrings/nginx-archive-keyring.gpg | awk -F: '/^pub/{getline; if ($1 == "fpr") print $10}')"; \
    test "$(printf '%s\n' "${EXPORTED_FPRS}" | grep -c '^')" -eq 3; \
    for fpr in ${KNOWN_FPRS}; do \
        printf '%s\n' "${EXPORTED_FPRS}" | grep -qx "${fpr}" || { \
            echo "exported keyring does not contain expected primary ${fpr}" >&2; \
            exit 1; \
        }; \
    done; \
    rm -f /tmp/nginx_signing.key

RUN printf '%s\n' \
        'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian trixie nginx' \
        > /etc/apt/sources.list.d/nginx-org-mainline.list \
 && printf '%s\n' \
        'Package: nginx' \
        'Pin: origin "nginx.org"' \
        'Pin-Priority: 1001' \
        > /etc/apt/preferences.d/nginx-org-mainline

# Resolve the package once from the pinned nginx.org mainline origin: the
# selected candidate must be offered by that repository (no Debian fallback),
# the version is read back from the authenticated .deb itself and reused for
# the matching source tarball, so the module and the runtime package always
# share the same nginx source.
RUN set -eu; \
    apt-get update -o APT::Update::Error-Mode=any; \
    mkdir -p /build; \
    apt-cache policy nginx > /build/policy-before.txt; \
    NGINX_CANDIDATE="$(awk '/^  Candidate:/{print $2; exit}' /build/policy-before.txt)"; \
    case "${NGINX_CANDIDATE}" in \
        [0-9]*-1~trixie) ;; \
        *) echo "unexpected apt candidate for nginx: ${NGINX_CANDIDATE}" >&2; exit 1 ;; \
    esac; \
    grep -A4 "Candidate: ${NGINX_CANDIDATE}" /build/policy-before.txt \
        | grep -q 'https://nginx.org/packages/mainline/debian' || { \
            echo "nginx candidate does not come from the nginx.org mainline repository" >&2; \
            cat /build/policy-before.txt >&2; \
            exit 1; \
        }; \
    cd /build; \
    apt-get download nginx; \
    NGINX_VERSION="$(dpkg-deb -f nginx_*_amd64.deb Version)"; \
    test "${NGINX_VERSION}" = "${NGINX_CANDIDATE}" || { \
        echo "downloaded nginx ${NGINX_VERSION} differs from pinned candidate ${NGINX_CANDIDATE}" >&2; \
        exit 1; \
    }; \
    NGINX_RELEASE="${NGINX_VERSION%%-*}"; \
    case "${NGINX_RELEASE}" in \
        [0-9]*.[0-9]*.[0-9]*) ;; \
        *) echo "unexpected nginx version: ${NGINX_VERSION}" >&2; exit 1 ;; \
    esac; \
    OLDEST="$(printf '%s\n%s\n' "${NGINX_MIN_RELEASE}" "${NGINX_RELEASE}" | sort -V | head -n1)"; \
    if [ "${OLDEST}" != "${NGINX_MIN_RELEASE}" ]; then \
        echo "nginx ${NGINX_RELEASE} is older than the accepted minimum ${NGINX_MIN_RELEASE}" >&2; \
        exit 1; \
    fi; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        -o /build/nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_RELEASE}.tar.gz"; \
    printf '%s\n%s\n' "${NGINX_VERSION}" "${NGINX_RELEASE}" > /build/nginx.versions; \
    echo "resolved nginx ${NGINX_VERSION} from the nginx.org mainline repository"

# Pin the fancyindex revision by fetching the archive for that exact commit.
RUN set -eu; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        -o /build/fancyindex.tar.gz \
        "https://codeload.github.com/aperezdc/ngx-fancyindex/tar.gz/${FANCYINDEX_REV}"; \
    mkdir -p /build/ngx-fancyindex; \
    tar -xzf /build/fancyindex.tar.gz --strip-components=1 -C /build/ngx-fancyindex; \
    if [ ! -f /build/ngx-fancyindex/config ]; then \
        echo "fancyindex archive missing its build config" >&2; \
        ls -la /build/ngx-fancyindex >&2; \
        exit 1; \
    fi; \
    if [ ! -f /build/ngx-fancyindex/ngx_http_fancyindex_module.c ]; then \
        echo "fancyindex archive missing the module source" >&2; \
        ls -la /build/ngx-fancyindex >&2; \
        exit 1; \
    fi

# Compile the dynamic module against the matching nginx source. --with-compat
# keeps the module loadable in the nginx.org official binaries.
RUN set -eu; \
    NGINX_RELEASE="$(sed -n 2p /build/nginx.versions)"; \
    mkdir -p /build/nginx-src; \
    tar -xzf /build/nginx.tar.gz --strip-components=1 -C /build/nginx-src; \
    cd /build/nginx-src; \
    ./configure --with-compat --add-dynamic-module=/build/ngx-fancyindex > /build/configure.log; \
    make modules > /build/modules.log; \
    test -s objs/ngx_http_fancyindex_module.so; \
    mkdir -p /out; \
    cp objs/ngx_http_fancyindex_module.so /out/; \
    cp /build/nginx_*_amd64.deb /out/nginx.deb; \
    cp /build/nginx.versions /out/nginx.versions; \
    echo "built fancyindex ${FANCYINDEX_REV} against nginx ${NGINX_RELEASE}"

FROM lscr.io/linuxserver/webtop:debian-xfce

LABEL maintainer="Aterfax"

# Enable 32 bit arch
RUN sudo dpkg --add-architecture i386 ; apt update

# Wine for running EXE
RUN apt-get update && apt-get install -y --no-install-recommends unzip wine wine64 wine32:i386 winbind libfreetype6 fonts-freefont-ttf wget cabextract xdotool xdg-utils xvfb git python3 python3-dev python3-pip p7zip-full grep socat nano vim

# Download the latest winetricks script (master="latest version") from Github.
RUN wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks && chmod +x winetricks
RUN mv winetricks /usr/bin

RUN mkdir /config/.wine && chown abc:users -R /config/.wine
RUN mkdir /config/.cache && chown abc:users -R /config/.cache

# nginx mainline migration: install the authenticated nginx.org mainline
# package resolved in the builder stage together with the fancyindex module
# compiled from the matching nginx source. The webtop configuration layout is
# preserved: the base image's init-nginx service still regenerates
# /etc/nginx/sites-available/default from /defaults/default.conf on every
# start, keeping the desktop websocket proxy, auth, TLS and file manager
# behaviour unchanged. The Debian nginx packages are replaced through apt's
# normal handling of the nginx.org package's declared Conflicts/Replaces
# fields; no dpkg/apt force flags are used.
COPY --from=nginx-module-builder /out/nginx.deb /tmp/nginx.deb
COPY --from=nginx-module-builder /out/ngx_http_fancyindex_module.so /tmp/ngx_http_fancyindex_module.so
COPY --from=nginx-module-builder /out/nginx.versions /tmp/nginx.versions
COPY ./src/nginx/nginx.conf /tmp/nginx.conf
COPY ./src/nginx/modules-enabled/50-mod-http-fancyindex.conf /tmp/50-mod-http-fancyindex.conf
COPY ./src/nginx/www-theme/ /usr/share/selkies/nginx-theme/

RUN set -eu; \
    export DEBIAN_FRONTEND=noninteractive; \
    test "$(dpkg --print-architecture)" = "amd64"; \
    . /etc/os-release; \
    test "$VERSION_CODENAME" = "trixie" || { \
        echo "runtime base is ${VERSION_CODENAME:-unknown}, expected trixie" >&2; \
        exit 1; \
    }; \
    apt-get update -o APT::Update::Error-Mode=any; \
    apt-get purge -y nginx nginx-common libnginx-mod-http-fancyindex; \
    apt-get install -y /tmp/nginx.deb; \
    test "$(dpkg-query -W -f '${Version}' nginx)" = "$(sed -n 1p /tmp/nginx.versions)"; \
    if dpkg -l nginx-common 2>/dev/null | grep -q '^ii'; then \
        echo "Debian nginx-common is still installed" >&2; \
        exit 1; \
    fi; \
    install -m 644 /tmp/nginx.conf /etc/nginx/nginx.conf; \
    rm -f /etc/nginx/conf.d/default.conf; \
    mkdir -p /etc/nginx/modules-enabled; \
    install -m 644 /tmp/50-mod-http-fancyindex.conf /etc/nginx/modules-enabled/50-mod-http-fancyindex.conf; \
    install -m 644 /tmp/ngx_http_fancyindex_module.so /usr/lib/nginx/modules/ngx_http_fancyindex_module.so; \
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled; \
    ln -sfn /usr/lib/nginx/modules /etc/nginx/modules; \
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default; \
    sed -e 's/CWS/8082/g' -e 's|SUBFOLDER|/|g' -e 's|REPLACE_DOWNLOADS_PATH|/tmp/desktop|g' \
        /defaults/default.conf > /etc/nginx/sites-available/default; \
    mkdir -p /config/ssl; \
    openssl req -new -x509 -days 1 -nodes -out /config/ssl/cert.pem -keyout /config/ssl/cert.key \
        -subj "/CN=nginx-build-validation" > /dev/null 2>&1; \
    /usr/sbin/nginx -t; \
    rm -rf /config/ssl; \
    rm -f /tmp/nginx.deb /tmp/ngx_http_fancyindex_module.so /tmp/nginx.versions /tmp/nginx.conf /tmp/50-mod-http-fancyindex.conf; \
    rm -rf /var/lib/apt/lists/*

# Placed after the migration step: the Debian nginx purge removes the whole
# /etc/nginx tree, so the guard's template must land in the tree recreated by
# the nginx.org package. The .template suffix matches no nginx include glob.
COPY ./src/nginx/files-location-block.template /etc/nginx/files-location-block.template

# Fail-closed guard: init-nginx-guard runs after init-nginx rewrites the site
# config on every boot, re-asserts the explicit HTTP/2-off setting, and
# validates the configuration with the mainline binary before svc-nginx may
# start. The dependency file registered into svc-nginx keeps nginx from
# launching whenever this guard fails.
COPY ./src/s6-services/s6-init-nginx-guard-oneshot /etc/s6-overlay/s6-rc.d/init-nginx-guard
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-nginx-guard \
 && touch etc/s6-overlay/s6-rc.d/svc-nginx/dependencies.d/init-nginx-guard

COPY ./src/s6-services/s6-init-migrate-dcs-oneshot /etc/s6-overlay/s6-rc.d/init-migrate-dcs-oneshot
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-migrate-dcs-oneshot

COPY ./src/s6-services/s6-init-socat-dns-forwarding-longrun /etc/s6-overlay/s6-rc.d/init-socat-dns-forwarding-longrun
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-socat-dns-forwarding-longrun

COPY ./src/s6-services/s6-init-winepreqs-oneshot /etc/s6-overlay/s6-rc.d/init-winepreqs-oneshot
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-winepreqs-oneshot


COPY ./src/s6-services/s6-init-desktop-setup-oneshot /etc/s6-overlay/s6-rc.d/init-desktop-setup-oneshot
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-desktop-setup-oneshot

COPY ./src/wine-dedicated-dcs-automated-installer /app/dcs_server/wine-dedicated-dcs-automated-installer
RUN chmod +x -R /app/dcs_server/wine-dedicated-dcs-automated-installer

COPY ./src/s6-services/s6-init-dcs-auto-installer-updater-oneshot /etc/s6-overlay/s6-rc.d/init-dcs-auto-installer-updater-oneshot
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-dcs-auto-installer-updater-oneshot

COPY ./src/s6-services/s6-init-dcs-server-autostart-longrun /etc/s6-overlay/s6-rc.d/init-dcs-server-autostart-longrun
RUN touch etc/s6-overlay/s6-rc.d/user/contents.d/init-dcs-server-autostart-longrun

COPY ./src/desktop-setup /app/dcs_server/desktop-setup
RUN chmod +x -R /app/dcs_server/desktop-setup

COPY ./src/helper_functions/logger_function /app/dcs_server/logger_function
RUN chmod +x -R /app/dcs_server/logger_function

COPY ./src/helper_functions/find_dcs_dirs_function /app/dcs_server/find_dcs_dirs_function
RUN chmod +x -R /app/dcs_server/find_dcs_dirs_function

COPY ./src/helper_functions/display_GUI_warning_function /app/dcs_server/display_GUI_warning_function
RUN chmod +x -R /app/dcs_server/display_GUI_warning_function

COPY ./src/helper_functions/get_dl_link /app/dcs_server/get_dl_link
RUN chmod +x -R /app/dcs_server/get_dl_link

# Add branding here to avoid it getting split into pieces in the output.
COPY ./src/branding /etc/s6-overlay/s6-rc.d/init-adduser/branding2
RUN sed -i '/cat \/etc\/s6-overlay\/s6-rc.d\/init-adduser\/branding/a\cat \/etc\/s6-overlay\/s6-rc.d\/init-adduser\/branding2' /etc/s6-overlay/s6-rc.d/init-adduser/run
