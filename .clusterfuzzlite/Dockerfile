FROM gcr.io/oss-fuzz-base/base-builder:v1
RUN apt-get update && \
    apt-get install -y pkg-config make autoconf autopoint zlib1g-dev flex bison gawk
COPY .clusterfuzzlite/build.sh $SRC
COPY . $SRC/elfutils
WORKDIR $SRC/elfutils
