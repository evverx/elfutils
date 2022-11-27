FROM gcr.io/oss-fuzz-base/base-builder:v1
RUN apt-get update && \
    apt-get install -y pkg-config make autoconf autopoint zlib1g-dev flex bison gawk
COPY . $SRC/elfutils
RUN git clone --depth 1 https://github.com/google/oss-fuzz && \
    cp oss-fuzz/projects/elfutils/build.sh $SRC/ && \
    cp oss-fuzz/projects/elfutils/fuzz-dwfl-core.c $SRC/ && \
    cp oss-fuzz/projects/elfutils/fuzz-libdwfl.c $SRC/ && \
    cp oss-fuzz/projects/elfutils/fuzz-libelf.c $SRC/
WORKDIR elfutils
