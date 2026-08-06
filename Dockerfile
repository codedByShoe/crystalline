FROM crystallang/crystal:1.21.0-alpine

WORKDIR /app

# Add llvm deps. The major must match what the base image was built against:
# the 1.21.0-alpine image is Alpine v3.22, whose repositories carry llvm20.
RUN apk add --update --no-cache --force-overwrite \
      llvm20-dev llvm20-static g++ libxml2-static zstd-static make

# Build crystalline.
COPY . /app/

RUN git clone -b 1.21.0 --depth=1 https://github.com/crystal-lang/crystal \
      && make -C crystal llvm_ext \
      && CRYSTAL_PATH=crystal/src:lib shards build crystalline \
      --no-debug --progress --stats --production --static --release \
      -Dpreview_mt --ignore-crystal-version \
      && rm -rf crystal
