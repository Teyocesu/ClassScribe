#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: package_windows_nsis.sh --publish-dir=PATH [--release-dir=PATH]
                               [--version=X.Y.Z] [--makensis=PATH]

Packages an existing win-x64 self-contained dotnet publish directory as a
portable ZIP and a per-user NSIS installer. This script runs on macOS/Linux;
the application itself must already have been built and tested for Windows.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
publish_dir=""
release_dir="$repo_root/.build/windows/release"
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
makensis_bin="${MAKENSIS:-makensis}"

for argument in "$@"; do
  case "$argument" in
    --publish-dir=*) publish_dir="${argument#*=}" ;;
    --release-dir=*) release_dir="${argument#*=}" ;;
    --version=*) version="${argument#*=}" ;;
    --makensis=*) makensis_bin="${argument#*=}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$publish_dir" ]]; then
  echo "--publish-dir is required." >&2
  exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use X.Y.Z format; got '$version'." >&2
  exit 2
fi
if [[ ! -d "$publish_dir" ]]; then
  echo "Publish directory does not exist: $publish_dir" >&2
  exit 2
fi
if [[ ! -x "$makensis_bin" ]] && ! command -v "$makensis_bin" >/dev/null 2>&1; then
  echo "makensis was not found. Install NSIS 3 or pass --makensis=PATH." >&2
  exit 2
fi

publish_dir="$(cd -- "$publish_dir" && pwd -P)"
mkdir -p -- "$release_dir"
release_dir="$(cd -- "$release_dir" && pwd -P)"

required_files=(
  "ClassScribe.exe"
  "sherpa-onnx-c-api.dll"
  "sherpa-onnx.dll"
  "runtimes/win-x64/whisper.dll"
  "runtimes/win-x64/ggml-whisper.dll"
  "runtimes/win-x64/ggml-base-whisper.dll"
  "runtimes/win-x64/ggml-cpu-whisper.dll"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -f "$publish_dir/$required_file" ]]; then
    echo "Required Windows release file is missing: $required_file" >&2
    exit 1
  fi
done
if find "$publish_dir" -type f -name '*.pdb' -print -quit | grep -q .; then
  echo "Debug symbol files must not be included in a release." >&2
  exit 1
fi
if find "$publish_dir" -type l -print -quit | grep -q .; then
  echo "Symbolic links must not be included in a Windows release." >&2
  exit 1
fi
if [[ "$(od -An -tx1 -N2 "$publish_dir/ClassScribe.exe" | tr -d '[:space:]')" != "4d5a" ]]; then
  echo "ClassScribe.exe is not a valid Windows PE executable." >&2
  exit 1
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/classscribe-windows-package.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

portable_name="ClassScribe-v${version}-windows-x64-portable"
portable_dir="$temporary_root/$portable_name"
portable_archive="$release_dir/${portable_name}.zip"
setup_file="$release_dir/ClassScribe-v${version}-windows-x64-setup.exe"

mkdir -p -- "$portable_dir"
cp -R -- "$publish_dir/." "$portable_dir/"
rm -rf -- "$portable_dir/runtimes/win-arm64" "$portable_dir/runtimes/win-x86"

rm -f -- "$portable_archive" "$portable_archive.sha256" "$setup_file" "$setup_file.sha256"
(
  cd -- "$temporary_root"
  zip -q -X -r "$portable_archive" "$portable_name"
)

makensis_arguments=(
  -V3
  "-DCLASSSCRIBE_VERSION=$version"
  "-DCLASSSCRIBE_PUBLISH_DIR=$portable_dir"
  "-DCLASSSCRIBE_OUTPUT_FILE=$setup_file"
  "-DCLASSSCRIBE_LICENSE_FILE=$repo_root/LICENSE"
  "-DCLASSSCRIBE_ICON_FILE=$repo_root/app/ClassScribe.Windows/src/ClassScribe.Windows/Assets/ClassScribe.ico"
  "$repo_root/app/ClassScribe.Windows/installer/ClassScribe.nsi"
)
if [[ "$(uname -s)" == "Darwin" ]]; then
  # Homebrew's native makensis aborts while generating language tables under
  # the C locale. Keep the workaround scoped to this child process.
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$makensis_bin" "${makensis_arguments[@]}"
else
  "$makensis_bin" "${makensis_arguments[@]}"
fi

write_sha256() {
  local path="$1"
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(LC_ALL=C LANG=C shasum -a 256 "$path" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(LC_ALL=C LANG=C sha256sum "$path" | awk '{print $1}')"
  else
    echo "Neither shasum nor sha256sum was found." >&2
    return 1
  fi
  printf '%s *%s\n' "$digest" "$(basename -- "$path")" > "$path.sha256"
}

write_sha256 "$portable_archive"
write_sha256 "$setup_file"

printf 'ClassScribe Windows v%s release assets:\n' "$version"
find "$release_dir" -maxdepth 1 -type f -print | sort
