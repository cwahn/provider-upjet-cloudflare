#!/usr/bin/env bash
# Called by publish-arsvivendi.yml on GitHub-hosted runners.
set -euo pipefail

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT

output="$PWD/_output/arsvivendi"
registry=ghcr.io/cwahn
groups=(config api d1 dns r2 workers zero)

repo_for() {
    if [[ "$1" == config ]]; then
        echo provider-family-cloudflare
    else
        echo "provider-cloudflare-$1"
    fi
}

install_crossplane() {
    [[ "$(uname -sm)" == "Linux aarch64" ]]
    local url="https://cli.crossplane.io/stable/${CROSSPLANE_CLI_VERSION:?}/bin/linux_arm64/crossplane"
    local sha
    case "$CROSSPLANE_CLI_VERSION" in
        v2.4.1) sha=28dff5115b378fcee064d4c4c097727626e3dc17f83f9590f0ab347b8cc7d992 ;;
        *) echo "No pinned arm64 Crossplane CLI checksum for $CROSSPLANE_CLI_VERSION" >&2; exit 1 ;;
    esac
    curl -fsSL --retry 3 "$url" -o "$workspace/crossplane"
    printf '%s  %s\n' "$sha" "$workspace/crossplane" | sha256sum -c -
    chmod 0755 "$workspace/crossplane"
    "$workspace/crossplane" xpkg --help
}

require_release_tag() {
    version=${GITHUB_REF_NAME:?}
    local regex='^v[0-9]+\.[0-9]+\.[0-9]+-arsvivendi\.[0-9]+$'
    [[ "$version" =~ $regex ]]
}

build() {
    local arch=${BUILD_ARCH:?}
    local context="$workspace/image" group repo image
    [[ "$arch" == amd64 || "$arch" == arm64 ]]
    mkdir -p "$context/bin/linux_${arch}" "$output/runtime-images"
    cp cluster/images/provider-upjet-cloudflare/{Dockerfile,terraformrc.hcl} "$context/"

    for group in "${groups[@]}"; do
        repo=$(repo_for "$group")
        image="arsvivendi-local/${repo}-${arch}"
        CGO_ENABLED=0 go build -mod=readonly -trimpath \
            -ldflags "-X github.com/wildbitca/provider-upjet-cloudflare/internal/version.Version=$version -s -w" \
            -o "$context/bin/linux_${arch}/$group" "./cmd/provider/$group"
        docker buildx build --load --platform "linux/$arch" --tag "$image" \
            --label 'org.opencontainers.image.source=https://github.com/cwahn/provider-upjet-cloudflare' \
            --label "org.opencontainers.image.revision=${GITHUB_SHA:?}" \
            --build-arg "SUBPACKAGE=$group" \
            --build-arg "OPENTOFU_VERSION=${OPENTOFU_VERSION:?}" \
            --build-arg TERRAFORM_PROVIDER_SOURCE=cloudflare/cloudflare \
            --build-arg "TERRAFORM_PROVIDER_VERSION=${TERRAFORM_PROVIDER_VERSION:?}" \
            --build-arg TERRAFORM_PROVIDER_DOWNLOAD_NAME=terraform-provider-cloudflare \
            --build-arg "TERRAFORM_PROVIDER_DOWNLOAD_URL_PREFIX=https://github.com/cloudflare/terraform-provider-cloudflare/releases/download/v${TERRAFORM_PROVIDER_VERSION}" \
            --build-arg "TERRAFORM_NATIVE_PROVIDER_BINARY=terraform-provider-cloudflare_v${TERRAFORM_PROVIDER_VERSION}" \
            "$context"
        [[ "$(docker image inspect --format '{{.Architecture}}' "$image")" == "$arch" ]]
        if ! docker run --rm --network none "$image" --enable-secret-cache=false --help >"$workspace/help" 2>&1; then
            cat "$workspace/help" >&2
            return 1
        fi
        grep -F -- 'enable-secret-cache' "$workspace/help"
        # The Docker archive includes manifest.json, which the CLI tarball reader requires.
        docker image save --output "$output/runtime-images/$repo.tar" "$image"
        rm "$context/bin/linux_${arch}/$group"
        docker image rm "$image"
    done
}

assert_image_arch() {
    local archive=$1 arch=$2 config
    config=$(tar -xOf "$archive" manifest.json | jq -er 'if length == 1 then .[0].Config else error("expected one runtime image") end')
    tar -xOf "$archive" "$config" | jq -e --arg arch "$arch" \
        '.os == "linux" and .architecture == $arch and .config.Entrypoint == ["provider"]'
}

publish() {
    local group repo target filename arch archive
    local -a paths
    for group in "${groups[@]}"; do
        repo=$(repo_for "$group")
        target="$registry/$repo:$version"
        if docker buildx imagetools inspect "$target" >"$workspace/inspect" 2>&1; then
            echo "Refusing to overwrite existing release: $target" >&2
            exit 1
        elif ! grep -Eiq 'manifest unknown|: not found$' "$workspace/inspect"; then
            cat "$workspace/inspect" >&2
            exit 1
        fi
        for arch in amd64 arm64; do
            archive="$output/artifacts/runtime-images-$arch/$repo.tar"
            assert_image_arch "$archive" "$arch"
            RUNTIME_IMAGE_TARBALL="$archive" bash scripts/build-family.sh \
                "$group" "$version" "$output" "$workspace/crossplane" arsvivendi-local "$arch" "linux_$arch"
            assert_image_arch "$output/linux_$arch/$repo-$version.xpkg" "$arch"
        done
    done
    for group in "${groups[@]}"; do
        repo=$(repo_for "$group")
        target="$registry/$repo:$version"
        filename="$repo-$version.xpkg"
        paths=("$output/linux_amd64/$filename" "$output/linux_arm64/$filename")
        "$workspace/crossplane" xpkg push -f "${paths[0]},${paths[1]}" "$target"
        docker buildx imagetools inspect --raw "$target" | jq -e '
            ([.manifests[].platform | [.os, .architecture]] | sort) ==
            [["linux", "amd64"], ["linux", "arm64"]]'
        docker buildx imagetools inspect "$target" | tee -a "$GITHUB_STEP_SUMMARY"
    done
}

case "${1:-}" in
    check-cli) install_crossplane ;;
    build) require_release_tag; build ;;
    publish) require_release_tag; install_crossplane; publish ;;
    *) echo 'Usage: arsvivendi-release.sh check-cli|build|publish' >&2; exit 2 ;;
esac
