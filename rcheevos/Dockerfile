# Mesma imagem dos outros cores (emuflow-ppsspp-core/Dockerfile): Emscripten 3.1.74 do EmulatorJS.
FROM emscripten/emsdk:3.1.74
RUN apt-get update && apt-get install -y --no-install-recommends p7zip-full zip jq pkg-config binutils-mips-linux-gnu git
ENV EM_CACHE=/work/.emcache
WORKDIR /work
