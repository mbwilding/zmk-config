default:
    @just --list --unsorted

config := absolute_path('config')
build := absolute_path('.build')
out := absolute_path('firmware')
draw := absolute_path('draw')

# parse build.yaml and filter targets by expression
_parse_targets $expr:
    #!/usr/bin/env bash
    attrs="[.board, .shield, .snippet, .\"artifact-name\"]"
    filter="(($attrs | map(. // [.]) | combinations), ((.include // {})[] | $attrs)) | join(\",\")"
    echo "$(yq -r "$filter" build.yaml | grep -v "^," | grep -i "${expr/#all/.*}")"

# build firmware for single board & shield combination
_build_single $board $shield $snippet $artifact *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    artifact="${artifact:-${shield:+${shield// /+}-}${board}}"
    build_dir="{{ build / '$artifact' }}"

    echo "Building firmware for $artifact..."
    west build -s zmk/app -d "$build_dir" -b $board {{ west_args }} ${snippet:+-S "$snippet"} -- \
        -DZMK_CONFIG="{{ config }}" ${shield:+-DSHIELD="$shield"}

    if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.uf2" "{{ out }}/$artifact.uf2"
    else
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.bin" "{{ out }}/$artifact.bin"
    fi

# build firmware for matching targets
build-specific expr *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    targets=$(just _parse_targets {{ expr }})

    [[ -z $targets ]] && echo "No matching targets found. Aborting..." >&2 && exit 1
    echo "$targets" | while IFS=, read -r board shield snippet artifact; do
        just _build_single "$board" "$shield" "$snippet" "$artifact" {{ west_args }}
    done

# Build
build: _parse_combos
    #!/usr/bin/env bash
    set -euo pipefail
    targets=$(just _parse_targets corne)

    echo "$targets" | while IFS=, read -r board shield snippet; do
        just _build_single "$board" "$shield" "$snippet"
    done

# Flash
flash $side:
    #!/usr/bin/env bash
    set -uo pipefail

    if [ "$side" != "left" ] && [ "$side" != "right" ]; then
      echo "Argument should be left or right." >&2
      exit 1
    fi

    if [[ "$(uname)" == "Darwin" ]]; then
        MOUNTPOINT="/Volumes/NICENANO"
    else
        MOUNTPOINT=$(ls -d /run/media/$USER/NICENANO* 2>/dev/null | head -n 1)
    fi

    if [ -z "$MOUNTPOINT" ]; then
      echo "Device not found: '$MOUNTPOINT' is empty." >&2
      exit 1
    fi
    if [ ! -d "$MOUNTPOINT" ]; then
      echo "Device not found or not a directory: '$MOUNTPOINT' does not exist or is not a directory." >&2
      exit 1
    fi
    if [ ! -w "$MOUNTPOINT" ]; then
      echo "Device not writeable: no write permission on '$MOUNTPOINT'." >&2
      exit 1
    fi

    cp "{{ out }}/corne_$side+nice_view_adapter+nice_view-nice_nano_v2.uf2" "$MOUNTPOINT/" 2>/dev/null
    echo "Flash complete"

# clear build cache and artifacts
clean:
    rm -rf {{ build }} {{ out }}

# clear all automatically generated files
clean-all: clean
    rm -rf .west zmk

# clear nix cache
clean-nix:
    nix-collect-garbage --delete-old

# parse & plot keymap
draw:
    #!/usr/bin/env bash
    set -euo pipefail

    keymap="corne"
    draw_config="{{ draw }}/config.yaml"
    base_yaml="{{ draw }}/base.yaml"
    combos_svg="{{ draw }}/combos.svg"
    base_svg="{{ draw }}/base.svg"
    keyboard="crkbd/rev4_1/mini"
    layout="LAYOUT_split_3x5_3"

    # keymap -c "$draw_config" parse --zmk-keymap "{{ config }}/$keymap.keymap" --virtual-layers Combos >"$base_yaml"
    # keymap -c "$draw_config" draw "$base_yaml" --zmk-keyboard $keyboard --layout-name $layout >"{{ draw }}/combos.svg"
    # yq -Yi '.combos.[].l = ["Combos"]' "$base_yaml"
    # keymap -c "$draw_config" draw "$base_yaml" --zmk-keyboard $keyboard --layout-name $layout >"{{ draw }}/base.svg"

    keymap -c "$draw_config" parse --zmk-keymap "{{ config }}/$keymap.keymap" >"$base_yaml"
    keymap -c "$draw_config" draw "$base_yaml" --zmk-keyboard $keyboard --layout-name $layout >"{{ draw }}/base.svg"

# initialize west
init:
    west init -l config
    west update --fetch-opt=--filter=blob:none
    west zephyr-export

# list build targets
list:
    @just _parse_targets all | sed 's/,*$//' | sort | column

# update west
update:
    west update --fetch-opt=--filter=blob:none

# upgrade zephyr-sdk and python dependencies
upgrade-sdk:
    nix flake update --flake .

[no-cd]
test $testpath *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    testcase=$(basename "$testpath")
    build_dir="{{ build / "tests" / '$testcase' }}"
    config_dir="{{ '$(pwd)' / '$testpath' }}"
    cd {{ justfile_directory() }}

    if [[ "{{ FLAGS }}" != *"--no-build"* ]]; then
        echo "Running $testcase..."
        rm -rf "$build_dir"
        west build -s zmk/app -d "$build_dir" -b native_posix_64 -- \
            -DCONFIG_ASSERT=y -DZMK_CONFIG="$config_dir"
    fi

    ${build_dir}/zephyr/zmk.exe | sed -e "s/.*> //" |
        tee ${build_dir}/keycode_events.full.log |
        sed -n -f ${config_dir}/events.patterns > ${build_dir}/keycode_events.log
    if [[ "{{ FLAGS }}" == *"--verbose"* ]]; then
        cat ${build_dir}/keycode_events.log
    fi

    if [[ "{{ FLAGS }}" == *"--auto-accept"* ]]; then
        cp ${build_dir}/keycode_events.log ${config_dir}/keycode_events.snapshot
    fi
    diff -auZ ${config_dir}/keycode_events.snapshot ${build_dir}/keycode_events.log
