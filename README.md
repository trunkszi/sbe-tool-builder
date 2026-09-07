# sbe-tool-builder

Prebuilt, JVM-free `sbe-tool` binaries for the
[Simple Binary Encoding (SBE)](https://github.com/aeron-io/simple-binary-encoding)
code generator, compiled with GraalVM Native Image.

This repository contains no SBE code. It is a build and release pipeline that
tracks upstream SBE releases, compiles the upstream `sbe-all.jar` into a
standalone executable, verifies the executable against the JVM, and publishes
it as a GitHub release. Each release here corresponds to exactly one upstream
SBE release and carries the same tag.

## Contents

- [Installation](#installation)
- [Usage](#usage)
- [Versioning](#versioning)
- [Supported platforms and generators](#supported-platforms-and-generators)
- [Release pipeline](#release-pipeline)
- [Building locally](#building-locally)
- [Native Image configuration](#native-image-configuration)
- [Repository layout](#repository-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Installation

Download the binary and its checksum for your platform from the
[releases page](../../releases), verify, and place it on your `PATH`:

```sh
VERSION=1.40.1
TARGET=linux-x86_64
BASE="https://github.com/trunkszi/sbe-tool-builder/releases/download/${VERSION}"

curl -fsSLO "${BASE}/sbe-tool-${VERSION}-${TARGET}"
curl -fsSLO "${BASE}/sbe-tool-${VERSION}-${TARGET}.sha256"
sha256sum -c "sbe-tool-${VERSION}-${TARGET}.sha256"

install -m 0755 "sbe-tool-${VERSION}-${TARGET}" /usr/local/bin/sbe-tool
```

Every release also ships a `SHA256SUMS` file covering all assets.

The binary is dynamically linked against `libc` and `libz` only. It requires no
Java runtime.

## Usage

The executable is a drop-in replacement for `java -jar sbe-all.jar`. It accepts
the same system properties and positional schema arguments as upstream
`SbeTool`:

```sh
# Generate Java codecs
sbe-tool -Dsbe.output.dir=generated -Dsbe.target.language=Java schema.xml

# Generate C++ codecs from a schema that uses XInclude, validating against the XSD
sbe-tool \
  -Dsbe.output.dir=generated \
  -Dsbe.target.language=cpp \
  -Dsbe.xinclude.aware=true \
  -Dsbe.validation.xsd=/path/to/sbe.xsd \
  -Dsbe.validation.stop.on.error=true \
  schema.xml

# Emit the intermediate representation, then generate from it
sbe-tool -Dsbe.output.dir=ir -Dsbe.generate.ir=true schema.xml
sbe-tool -Dsbe.output.dir=generated -Dsbe.target.language=golang ir/schema.sbeir
```

Refer to the
[upstream documentation](https://github.com/aeron-io/simple-binary-encoding/wiki/Sbe-Tool-Guide)
for the full list of properties.

Note that `sbe.validation.xsd` takes a file system path. The `sbe.xsd` file is
part of the upstream repository under `sbe-tool/src/main/resources/fpl/`.

## Versioning

| Build source | Release tag | Release type |
|---|---|---|
| Upstream release tag, e.g. `1.40.1` | `1.40.1` | Release |
| Branch or commit, e.g. `master` | `<version.txt>-g<short sha>`, e.g. `1.41.0-SNAPSHOT-gea0caa9` | Pre-release |

Release tags intentionally mirror upstream tags without a `v` prefix so that a
release here can be looked up directly by SBE version. Asset names follow the
pattern `sbe-tool-<version>-<target>`.

Releases are immutable once published. A rebuild of an existing tag requires the
`force` input on a manual workflow run and replaces the assets in place.

## Supported platforms and generators

| Target | Runner | Status |
|---|---|---|
| `linux-x86_64` | `ubuntu-latest` | Built and released |

Additional targets can be added as matrix entries in
`.github/workflows/release.yml`; the build script derives the target label from
`uname` when `TARGET` is not set.

The native binary supports every generator bundled in `sbe-all.jar`:
`Java`, `C`, `cpp`, `golang` and `rust`. Generators that upstream loads by fully
qualified class name from an external classpath (the C# generator, for example)
are not available in a closed-world native image.

## Release pipeline

`.github/workflows/release.yml` runs on a daily schedule and on manual dispatch.

1. **Resolve.** Determine the upstream revision to build. By default this is the
   newest upstream release tag; a manual run may pass any tag, branch or commit
   as `upstream_ref`. If a release with the resulting tag already exists, the
   run stops here unless `force` is set.
2. **Build.** On each matrix runner: install `build-essential` and
   `zlib1g-dev`, set up GraalVM Community 21.0.2 via `graalvm/setup-graalvm`,
   and run `scripts/build.sh` pinned to the commit and version chosen in step 1.
   The Gradle cache is keyed on the upstream commit.
3. **Publish.** Collect the artifacts from all matrix jobs, write `SHA256SUMS`,
   and create the release with `gh release create`, or upload into the existing
   release when forcing a rebuild. Branch and commit builds are marked as
   pre-releases.

Authentication uses the workflow's built-in `secrets.GITHUB_TOKEN` together with
`permissions: contents: write`. No personal access token or repository secret
is required.

## Building locally

Requirements: Linux x86_64, Debian or Ubuntu, `git`, `curl`, and network access
to GitHub, Gradle, and Maven Central.

```sh
scripts/install-toolchain.sh              # apt packages, SDKMAN!, GraalVM CE 21.0.2
source "$HOME/.sdkman/bin/sdkman-init.sh"
sdk use java 21.0.2-graalce

scripts/build.sh                          # newest upstream release tag
scripts/build.sh 1.40.1                   # a specific upstream tag
scripts/build.sh master                   # upstream master (pre-release versioning)
```

`scripts/build.sh` performs the complete pipeline for one target:

1. Fetch the resolved upstream commit with a shallow clone.
2. Run `./gradlew :sbe-all:jar` to build the shaded `sbe-all.jar`.
3. Execute `sbe-all.jar` on the JVM under the Native Image tracing agent across
   a fixed corpus: every supported target language over four upstream schemas
   (with XInclude, XSD validation and precedence checks enabled), IR generation,
   IR consumption, and a deliberately invalid schema. The agent output is merged
   over the checked-in baseline in `config/native-image/`. The JVM outputs are
   retained as the reference.
4. Run `native-image` to produce `sbe-tool`.
5. Execute the same corpus with the native binary and `diff -r` every generated
   file against the JVM reference. The invalid schema must be rejected with an
   XSD error message. Any deviation fails the build.
6. Write the asset, its `.sha256`, `VERSION` and `COMMIT` to `dist/`.

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `UPSTREAM_REPO` | `https://github.com/aeron-io/simple-binary-encoding.git` | Upstream git URL |
| `UPSTREAM_REF` | newest release tag | Ref to build when no positional argument is given |
| `UPSTREAM_COMMIT`, `UPSTREAM_VERSION` | unset | When both are set, skip resolution and build exactly that commit under that version |
| `TARGET` | `<os>-<arch>` from `uname` | Platform label in the asset name |
| `BUILD_DIR` | `./build` | Scratch directory |
| `DIST_DIR` | `./dist` | Output directory |

## Native Image configuration

The image is built with:

```sh
native-image \
  --no-fallback \
  -jar sbe-all.jar \
  -H:IncludeResources=".*\.xsd$" \
  -H:IncludeResources="golang/templates/.*" \
  -H:Name=sbe-tool \
  -H:ConfigurationFileDirectories=<merged config> \
  --initialize-at-build-time \
  --initialize-at-run-time=org.agrona.BufferUtil \
  --add-opens java.base/jdk.internal.misc=ALL-UNNAMED
```

Each flag beyond the defaults addresses a concrete failure observed with
`sbe-all.jar` 1.40.1 on GraalVM CE 21.0.2:

| Flag | Reason |
|---|---|
| `--initialize-at-run-time=org.agrona.BufferUtil` | The class computes Unsafe array offsets in its static initialiser. With blanket build-time initialisation the builder either fails to initialise it or would bake host-JVM offsets into the image heap. |
| `--add-opens java.base/jdk.internal.misc=ALL-UNNAMED` | Agrona's `UnsafeApi` accesses `jdk.internal.misc.Unsafe`. Upstream passes the same flag to its own JVM invocations. Without it, IR encoding and decoding fail at run time. |
| `-H:IncludeResources="golang/templates/.*"` | The Go generator reads its marshalling templates from the classpath at run time. |
| `-H:IncludeResources=".*\.xsd$"` | Embeds `fpl/sbe.xsd`. SBE itself reads the validation XSD from a file path, so this is retained for parity with the original build command rather than for functionality. |
| Reflection configuration | The JDK XPath implementation instantiates function classes such as `FuncLocalPart` reflectively, and JAXP factories are resolved by name. |
| Resource bundles | Xerces and XPath error messages are loaded from resource bundles that are otherwise dropped from the image, turning schema errors into `MissingResourceException`. |

`config/native-image/` holds the hand-maintained baseline for the reflection and
resource entries above. The tracing agent run in `scripts/build.sh` extends it
per build, so new reflective uses introduced upstream are picked up
automatically as long as the corpus exercises them.

## Repository layout

| Path | Purpose |
|---|---|
| `.github/workflows/release.yml` | Scheduled and manual build, verification and release publishing |
| `scripts/resolve-upstream.sh` | Selects the upstream ref and derives commit, version, tag and pre-release flag |
| `scripts/build.sh` | Fetch, Gradle build, tracing agent, `native-image`, differential smoke test, `dist/` output |
| `scripts/install-toolchain.sh` | Local toolchain bootstrap for Debian and Ubuntu |
| `config/native-image/` | Baseline reflection and resource configuration |

## Troubleshooting

**`Could not load any resource bundle by ...XMLSchemaMessages`** or
**`TransformerException: ...FuncLocalPart.<init>()`** at run time. The image was
built without the reflection and resource configuration. Ensure
`-H:ConfigurationFileDirectories` points at a directory containing the baseline
files from `config/native-image/`.

**`Class initialization of org.agrona.UnsafeApi failed`** during
`native-image`. The `--add-opens` flag is missing from the `native-image`
invocation.

**Go output is empty.** The `golang/templates/.*` resource pattern is missing.

**`could not find dimensionType: groupSizeEncoding`** on the upstream example
schema. The schema uses XInclude; pass `-Dsbe.xinclude.aware=true`.

**`No code generator for name: ...`** The language name is case-sensitive and
must be one of `Java`, `C`, `cpp`, `golang`, `rust`.

## License

The build scripts and configuration in this repository are licensed under the
Apache License 2.0 (see `LICENSE`). Released binaries are compiled from upstream
SBE, which is also distributed under the Apache License 2.0, and include its
dependencies under their respective licenses.
