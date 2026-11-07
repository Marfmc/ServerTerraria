FROM jacobsmile/tmodloader1.4:latest

# Instala pacotes essenciais:
# - libicu-dev: Obrigatório para o .NET 8 suportar culturas/idiomas do Terraria (evita CultureNotFoundException)
# - zip / unzip / curl / python3 / procps: Usados nos sistemas de Auto-Backup, Resolução de Mods da Steam e Watchdog
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libicu-dev \
        zip \
        unzip \
        curl \
        python3 \
        procps \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Atualização Oficial do tModLoader via GitHub Releases (Contingência quando o Docker Hub estiver desatualizado)
ARG TMOD_OFFICIAL_VERSION=""
RUN if [ -n "$TMOD_OFFICIAL_VERSION" ]; then \
        echo "==================================================================" && \
        echo "[BUILD] Forçando atualização do tModLoader com release oficial GitHub: ${TMOD_OFFICIAL_VERSION}" && \
        echo "==================================================================" && \
        if [ "$TMOD_OFFICIAL_VERSION" = "latest" ]; then \
            DOWNLOAD_URL="https://github.com/tModLoader/tModLoader/releases/latest/download/tModLoader.zip"; \
        else \
            case "$TMOD_OFFICIAL_VERSION" in \
                v*) TAG="$TMOD_OFFICIAL_VERSION" ;; \
                *)  TAG="v$TMOD_OFFICIAL_VERSION" ;; \
            esac; \
            DOWNLOAD_URL="https://github.com/tModLoader/tModLoader/releases/download/${TAG}/tModLoader.zip"; \
        fi && \
        curl -fsSL -o /tmp/tmodloader.zip "$DOWNLOAD_URL" && \
        unzip -o /tmp/tmodloader.zip -d /terraria-server && \
        rm -f /tmp/tmodloader.zip && \
        chmod +x /terraria-server/LaunchUtils/*.sh /terraria-server/tModLoader* 2>/dev/null || true; \
    fi

# Copia os scripts de automação, resiliência, backup e gerenciamento de mods
COPY scripts/ /terraria-server/scripts/

# Converte quebras de linha CRLF (Windows) para LF (Linux) e aplica permissão de execução
RUN sed -i 's/\r$//' /terraria-server/scripts/*.sh /terraria-server/scripts/*.py && \
    chmod +x /terraria-server/scripts/*.sh /terraria-server/scripts/*.py && \
    cp -f /terraria-server/scripts/entrypoint_custom.sh /terraria-server/entrypoint.sh && \
    chmod +x /terraria-server/entrypoint.sh
