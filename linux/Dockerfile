# Build + run image for webkit-cli on Linux: Swift 6.4 (Debian trixie) + WPE WebKit 2.54 from sid
# (the first WPE with the WPEPlatform headless display and webkit_web_view_get_snapshot).
FROM swift:6.4-trixie
RUN echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/sid.list \
 && printf 'Package: *\nPin: release a=sid\nPin-Priority: 100\n' > /etc/apt/preferences.d/sid \
 && apt-get update \
 && apt-get install -y --no-install-recommends -t sid libwpewebkit-2.0-dev libcairo2-dev pkg-config ca-certificates \
    gstreamer1.0-plugins-base bubblewrap fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*
