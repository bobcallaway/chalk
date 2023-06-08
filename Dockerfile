FROM ghcr.io/crashappsec/nim:alpine-latest as compile

# FIXME
RUN nimble install -y https://github.com/crashappsec/con4m \
        https://github.com/crashappsec/nimutils \
        nimSHA2@0.1.1 \
        glob@0.11.2 \
        https://github.com/viega/zippy

ENV PATH="/root/.nimble/bin:${PATH}"

# we are doing this to only compile chalk once when we build this image
# ("compile"), and then, if we want to re-compile, we will do so via the cmd in
# docker-compose and rely on volume mounts to actually have an updated binary
# _without_ rebuilding the whole image. This step only ships you the
# dependencies you need to
FROM compile as build

ARG CHALK_BUILD="release"

WORKDIR /chalk

COPY . /chalk/

RUN --mount=type=cache,target=/root/.nimble,sharing=locked \
    yes | nimble $CHALK_BUILD

# -------------------------------------------------------------------

# published as ghcr.io/crashappsec/chalk:latest

FROM alpine:latest as release

RUN apk add --no-cache pcre gcompat

WORKDIR /

COPY --from=build /chalk/chalk /chalk

CMD /chalk