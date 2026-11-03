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

# Copia os scripts de automação, resiliência, backup e gerenciamento de mods
COPY scripts/ /terraria-server/scripts/

# Converte quebras de linha CRLF (Windows) para LF (Linux) e aplica permissão de execução
RUN sed -i 's/\r$//' /terraria-server/scripts/*.sh /terraria-server/scripts/*.py && \
    chmod +x /terraria-server/scripts/*.sh /terraria-server/scripts/*.py && \
    cp -f /terraria-server/scripts/entrypoint_custom.sh /terraria-server/entrypoint.sh && \
    chmod +x /terraria-server/entrypoint.sh
