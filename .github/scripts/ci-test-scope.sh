#!/usr/bin/env bash

set -euo pipefail

run_all=false
run_build=false
run_kit=false
run_graph=false
run_engine=false
run_capture_nodes=false

if (($# == 0)); then
  echo "all"
  exit 0
fi

for path in "$@"; do
  case "$path" in
    Package.swift | Makefile | .swift-format | .github/* | scripts/*)
      run_all=true
      ;;
    Sources/RilliyaCore/*)
      run_build=true
      run_kit=true
      run_capture_nodes=true
      ;;
    Sources/RilliyaRealtime/*)
      run_build=true
      run_kit=true
      run_engine=true
      run_capture_nodes=true
      ;;
    Sources/RilliyaDiscovery/* | Sources/RilliyaDSP/* | Sources/RilliyaPlayback/* | Sources/RilliyaFilePlayback/* | Sources/RilliyaFileWriting/* | Sources/RilliyaNetworkAudio/*)
      run_build=true
      run_kit=true
      ;;
    Sources/RilliyaCapture/*)
      run_build=true
      run_kit=true
      run_capture_nodes=true
      ;;
    Sources/RilliyaGraph/*)
      run_build=true
      run_graph=true
      run_engine=true
      run_capture_nodes=true
      ;;
    Sources/RilliyaEngine/*)
      run_build=true
      run_engine=true
      run_capture_nodes=true
      ;;
    Sources/RilliyaCaptureNodes/*)
      run_build=true
      run_capture_nodes=true
      ;;
    Tests/RilliyaKitTests/*)
      run_build=true
      run_kit=true
      ;;
    Tests/RilliyaGraphTests/*)
      run_build=true
      run_graph=true
      ;;
    Tests/RilliyaEngineTests/*)
      run_build=true
      run_engine=true
      ;;
    Tests/RilliyaCaptureNodesTests/*)
      run_build=true
      run_capture_nodes=true
      ;;
    Examples/*)
      run_build=true
      ;;
    *.md | Documentation/* | LICENSE)
      ;;
    *)
      run_all=true
      ;;
  esac
done

if [[ "$run_all" == true ]]; then
  echo "all"
  exit 0
fi

targets=()
[[ "$run_kit" == true ]] && targets+=("RilliyaKitTests")
[[ "$run_graph" == true ]] && targets+=("RilliyaGraphTests")
[[ "$run_engine" == true ]] && targets+=("RilliyaEngineTests")
[[ "$run_capture_nodes" == true ]] && targets+=("RilliyaCaptureNodesTests")

if ((${#targets[@]} == 0)); then
  if [[ "$run_build" == true ]]; then
    echo "build"
  else
    echo "skip"
  fi
  exit 0
fi

joined=$(IFS='|'; echo "${targets[*]}")
echo "^(${joined})\\."
