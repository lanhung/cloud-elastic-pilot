# syntax=docker/dockerfile:1.7
ARG CUDA_DEVEL_IMAGE
ARG CUDA_RUNTIME_IMAGE

FROM ${CUDA_DEVEL_IMAGE} AS build
WORKDIR /src
COPY examples/e09-gpu-dra-mig/main.cu .
RUN nvcc --std=c++17 --cudart shared -O2 -lineinfo \
    -Xcompiler=-Wall,-Wextra,-Werror \
    -o /e09-gpu-probe main.cu

FROM ${CUDA_RUNTIME_IMAGE}
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown
ARG CUDA_DEVEL_IMAGE
ARG CUDA_RUNTIME_IMAGE
LABEL org.opencontainers.image.title="Cloud Elastic Pilot E09 CUDA probe" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      hooke.io/cuda-devel-base="${CUDA_DEVEL_IMAGE}" \
      hooke.io/cuda-runtime-base="${CUDA_RUNTIME_IMAGE}"
COPY --from=build /e09-gpu-probe /usr/local/bin/e09-gpu-probe
ENV HOME=/tmp
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/e09-gpu-probe"]
