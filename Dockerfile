FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ---------- System dependencies ----------
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    zip \
    bash \
    jq \
    build-essential \
    make \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    sqlite3 \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxml2-utils\
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev \
    ca-certificates \
    uuid-runtime \
    docker.io \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*


# ---------- yq ----------
RUN wget https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -O /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# ---------- AWS CLI ----------
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && ./aws/install && \
    rm -rf awscliv2.zip aws

# ---------- SDKMAN + Java 8, 11, 17 ----------
ENV SDKMAN_DIR="/root/.sdkman"
ENV PATH="${SDKMAN_DIR}/candidates/java/current/bin:$PATH"

RUN curl -s "https://get.sdkman.io" | bash && \
    bash -c "source $SDKMAN_DIR/bin/sdkman-init.sh && \
    sdk install java 8.0.392-tem && \
    sdk install java 11.0.23-tem && \
    sdk install java 17.0.9-tem && \
    sdk install java 21.0.7-tem && \
    sdk default java 21.0.7-tem && \
    sdk install maven 3.9.6 && \
    sdk default maven 3.9.6"

RUN echo "export SDKMAN_DIR=\"/root/.sdkman\"" >> ~/.bashrc && \
    echo "[[ -s \"\$SDKMAN_DIR/bin/sdkman-init.sh\" ]] && source \"\$SDKMAN_DIR/bin/sdkman-init.sh\"" >> ~/.bashrc

# ---------- Python 3.10, 3.11, 3.12 via pyenv ----------
ENV PYENV_ROOT="/root/.pyenv"
ENV PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"

RUN git clone https://github.com/pyenv/pyenv.git $PYENV_ROOT && \
    $PYENV_ROOT/bin/pyenv install 3.10.14 && \
    $PYENV_ROOT/bin/pyenv install 3.11.9 && \
    $PYENV_ROOT/bin/pyenv install 3.12.0 && \
    $PYENV_ROOT/bin/pyenv install 3.13.0 && \
    $PYENV_ROOT/bin/pyenv global 3.13.0 && \
    $PYENV_ROOT/bin/pyenv rehash

# ---------- Install Python dependencies ----------
COPY dependencies/python.txt /tmp/python.txt
RUN pip install --no-cache-dir -r /tmp/python.txt

# ---------- Node.js via nvm + global dependencies ----------
ENV NVM_DIR="/root/.nvm"
ENV NODE_VERSION="22"
ENV PATH="$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH"

COPY dependencies/node.txt /tmp/node.txt

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install $NODE_VERSION && \
    nvm use $NODE_VERSION && \
    nvm alias default $NODE_VERSION && \
    ln -s $NVM_DIR/versions/node/v$NODE_VERSION/bin/node /usr/local/bin/node && \
    ln -s $NVM_DIR/versions/node/v$NODE_VERSION/bin/npm /usr/local/bin/npm && \
    ln -s $NVM_DIR/versions/node/v$NODE_VERSION/bin/npx /usr/local/bin/npx && \
    npm install -g $(cat /tmp/node.txt | xargs)"

# ---------- Colored Bash Prompt + pyenv/nvm env setup ----------
RUN echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc && \
    echo 'export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"' >> ~/.bashrc && \
    echo 'eval "$(pyenv init --path)"' >> ~/.bashrc && \
    echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.bashrc && \
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> ~/.bashrc && \
    echo 'nvm use default > /dev/null' >> ~/.bashrc && \
    echo '' >> ~/.bashrc && \
    echo '# Colored bash prompt' >> ~/.bashrc && \
    echo 'force_color_prompt=yes' >> ~/.bashrc && \
    echo 'if [ "$force_color_prompt" = yes ]; then' >> ~/.bashrc && \
    echo '  PS1="\[\e[0;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ "' >> ~/.bashrc && \
    echo 'fi' >> ~/.bashrc && \
    echo '' >> ~/.bashrc

# ---------- Fix for entrypoint ----------
RUN echo 'export PYENV_ROOT="/root/.pyenv"' >> /etc/profile.d/pyenv.sh && \
    echo 'export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"' >> /etc/profile.d/pyenv.sh && \
    echo 'eval "$(pyenv init --path)"' >> /etc/profile.d/pyenv.sh

RUN echo 'export NVM_DIR="/root/.nvm"' >> /etc/profile.d/nvm.sh && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /etc/profile.d/nvm.sh && \
    echo 'nvm use default > /dev/null 2>&1 || true' >> /etc/profile.d/nvm.sh

RUN echo 'export SDKMAN_DIR="/root/.sdkman"' >> /etc/profile.d/sdkman.sh && \
    echo '[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"' >> /etc/profile.d/sdkman.sh

RUN echo 'export SDKMAN_DIR="/root/.sdkman"' >> ~/.bashrc && \
    echo '[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"' >> ~/.bashrc && \
    echo 'export PATH="$SDKMAN_DIR/candidates/maven/current/bin:$PATH"' >> ~/.bashrc

RUN echo 'export SDKMAN_DIR="/root/.sdkman"' >> /etc/profile.d/sdkman.sh && \
    echo '[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"' >> /etc/profile.d/sdkman.sh && \
    echo 'export PATH="$SDKMAN_DIR/candidates/maven/current/bin:$PATH"' >> /etc/profile.d/sdkman.sh \

# ---------- Copy and register scripts without .sh ----------
WORKDIR /tmp/scripts
COPY scripts/ .

RUN chmod +x *.sh && \
    for script in *.sh; do \
        name=$(basename "$script" .sh); \
        cp "$script" /usr/local/bin/"$name"; \
        chmod +x /usr/local/bin/"$name"; \
    done

# ---------- Final settings ----------
WORKDIR /
SHELL ["/bin/bash", "-c"]
CMD ["bash"]