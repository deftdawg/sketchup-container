FROM ubuntu:22.04
# Ubuntu release name For WineHQ repo source 
ARG VERSION_CODENAME=jammy
# Download URL for SketchUp Make 2017 (from wayback machine)
ARG sketchup_exe_url=https://web.archive.org/web/20220217222923/https://download.sketchup.com/sketchupmake-2017-2-2555-90782-en-x64.exe

RUN apt update
RUN apt install -y software-properties-common wget file p7zip \ 
                   libuid-wrapper winbind zip winetricks xvfb \
                   xterm konsole zenity nano less bat && \
    echo y | winetricks --self-update

RUN dpkg --add-architecture i386 && \
    wget -nc https://dl.winehq.org/wine-builds/winehq.key && \
    apt-key add winehq.key && \
    apt-add-repository "deb https://dl.winehq.org/wine-builds/ubuntu/ ${VERSION_CODENAME} main" && \
    apt update && \
    apt install -y --install-recommends winehq-staging

# Create "user" account
ARG gid=1000
ARG uid=1000
RUN groupadd -g $gid user && \
    useradd -u $uid -g user user && \
    mkdir /data && chown user /data && \
    mkdir -p /home/user && chown -R user:user /home/user

USER user

WORKDIR /home/user

# Wine Environment Config
ENV WINEPREFIX=/home/user/.wine
ENV WINEARCH=win64

# unset WINEDEBUG if troubleshooting bugs
ENV WINEDEBUG=fixme-all

# Prevent Wine from trying to install mono and gecko
ENV WINEDLLOVERRIDES=mscoree=d;mshtml=d

# Check that our ulimit -n value is higher than the default 1024
# if not, error out asking user to run build again with: 
#   podman build --ulimit nofile=32767 ...
RUN if [ "$(ulimit -n)" -lt 1025 ]; then \
        /usr/bin/echo -e "Error: open files limit (ulimit -n) is too low! \n\t99% of builds .NET will fail to install with a low files limit\n\t FIX: run this build again with: 'podman build --ulimit nofile=32767 ...'" >&2; \
        exit 1; \
    fi

# Install .NET 4.5.2, reset to Windows 7, install VC 2015 Runtime, try to clean up temp files
RUN xvfb-run -a winetricks -q \
		dotnet452 \
        win7 \
		vcrun2015 \
	2>/dev/null && \
	(rm -rf  ~/.cache ~/.config ~/.local /tmp/* || true)

# Save SketchUp STL import/export plugin for 3d printing .stl file support to Desktop for easy installation
RUN wget https://github.com/tbultel/sketchup-stl/archive/master.zip && \
    unzip master.zip && \
    cd sketchup-stl-master/src && \
    zip -r ~/.wine/drive_c/users/user/Desktop/sketchup-stl.rbz sketchup-stl sketchup-stl.rb && \
    cd - && \
    rm -rf master.zip sketchup-stl-master

# Download Sketchup
RUN wget $sketchup_exe_url

# 1. Create a temporary "Make" directory
# 2. Extract the installer (autoextracting .exe's spawn uncontrollable processes)
# 3. Silently install SketchUp
# 4. Clean up the temporary folder and the SketchUp installer
RUN rm -rf Make && \
    mkdir -p Make && \
    cd Make && \
    sh -c "7zr x ../\$(echo $sketchup_exe_url | rev | cut -d/ -f1 | rev)" && \
    wine64 msiexec /i SketchUp2017-x64.msi /quiet && \
    sh -c "rm -rf ../Make ../\$(echo $sketchup_exe_url | rev | cut -d/ -f1 | rev)"

# Accept SketchUp's EULA and disable update checking to stop the new version pop-up
# FIXME: wine regedit's update doesn't seem to sync to disk in the user.reg until ~5 seconds after it exits (workaround = sleep 10 and grep for it).  If you get stuck here when building, try increasing the sleep delay.
RUN /usr/bin/echo -e 'REGEDIT4\n\n[HKEY_CURRENT_USER\\Software\\SketchUp\\SketchUp 2017\\Preferences]\n"CheckForUpdates"=dword:00000000\n\n[HKEY_CURRENT_USER\\Software\\SketchUp\\SketchUp 2017\\Common]\n"AcceptedEULA"=dword:00000001' \
    > disable-updates-check.reg && wine regedit disable-updates-check.reg && sleep 10 && grep -n CheckForUpdates .wine/*.reg

ARG CACHEBUST=1

COPY wine-tmp-list wine-data-list /
RUN mkdir .tmp-template
RUN while read i ; do mkdir -p "$( dirname .tmp-template/"$i" )" && ( test -e .wine/"$i" || mkdir -p .wine/"$i" ) && mv .wine/"$i" .tmp-template/"$i" && ln -sv /tmp/wine/"$i" .wine/"$i" ; done < /wine-tmp-list
RUN while read i ; do mkdir -p "$( dirname .wine-template/"$i" )" && ( test -e .wine/"$i" || mkdir -p .wine/"$i" ) && mv .wine/"$i" .wine-template/"$i" && ln -sv /data/.sketchup-run/wine/"$i" .wine/"$i" ; done < /wine-data-list

COPY run-sketchup /usr/local/bin/
# Debug run-xterm entrypoint
COPY run-xterm /usr/local/bin/
RUN /usr/bin/echo -e "alias ls='ls --color'\nalias grep='grep --color'\nalias bat='batcat'" > ~/.bashrc

# FIXME: Fix /data mountpoint to mount podman host system's $HOME
RUN rm -f /home/user/.wine/drive_c/users/user/"My Documents" && ln -sv /data /home/user/.wine/drive_c/users/user/"My Documents"

# Add Favorites to Wine File Explorer file open dialog
RUN cd /home/$(whoami)/.wine/drive_c/users/$(whoami)/Favorites && \
    ln -s /data Home && \
    ln -s /data/Desktop && \
    ln -s /data/Downloads

# Install SketchUp Plugins in the host's home directory
RUN mkdir /data/SketchUp\ Plugins && \
    ln -s /data/SketchUp\ Plugins /home/$(whoami)/.wine/drive_c/users/$(whoami)/AppData/Roaming/SketchUp

ENTRYPOINT [ "/usr/local/bin/run-sketchup" ]

LABEL RUN 'podman run --userns=keep-id --network=host --ipc=host --pid=host --tmpfs /tmp -v /tmp/.wine-$(id -u) -e DISPLAY=$DISPLAY --security-opt=label:type:spc_t --user=$(id -u):$(id -g) -v /tmp/.X11-unix/X0:/tmp/.X11-unix/X0 -v ${HOME}:/data:Z --rm localhost/sketchup'

