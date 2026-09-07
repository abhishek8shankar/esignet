#!/bin/bash

# --- Start Xvfb so headless Chromium has a display to attach to ---
# DISPLAY is set to :99 in the image, but nothing was starting the X server on
# it before Chrome launched. Without this, headless Chrome under xvfb crashes
# or hangs waiting for a display (see mosip/esignet#2544 §2, §3.10).
Xvfb "$DISPLAY" -screen 0 1920x1080x24 &
XVFB_PID=$!
trap 'kill -TERM "$XVFB_PID" 2>/dev/null || true' EXIT

echo "Listing files in /home/mosip/:"
ls -l /home/mosip/

ls -l /home/mosip/
echo "Listing files in /home/mosip/:"

echo "Listing feature files in /home/mosip/featurefiles/:"
ls -l /home/mosip/featurefiles/

echo "/home/mosip/src/test/resources/"
ls -l /home/mosip/src/test/resources/

echo "/home/mosip/test-output/SparkReport/"
ls -l /home/mosip/test-output/SparkReport/

echo "/home/mosip/src/test/resources/extent.properties"
ls -l /home/mosip/src/test/resources/extent.properties

echo "/home/mosip/src/"
ls -l /home/mosip/src/

echo "/home/mosip/src/main/"
ls -l /home/mosip/src/main/

echo "/home/mosip/src/main/java/"
ls -l /home/mosip/src/main/java/

echo "/home/mosip/src/main/java/utils/"
ls -l /home/mosip/src/main/java/utils/

java --version

# Job env expected (mosip/esignet#2544 §4):
#   ENV_ENDPOINT (required), ENV_USER, MODULES, ENV_TESTLEVEL, JAVA_EXTRA_OPTS
# Optional scenario filters, left out of the command entirely when unset so
# apitest-commons' ConfigManager falls back to config.properties/JAR defaults
# instead of getting an empty override (env wins over config.properties, and
# an empty env value still wins - see the issue's "silent trap" note):
#   CUCUMBER_FILTER_TAGS, RUN_ONLY_SCENARIO, FEATURE_FILES_TO_EXECUTE
JAVA_ARGS=(-DrunDocker=yes -Dheadless=true)
JAVA_ARGS+=(-Denv.endpoint="$ENV_ENDPOINT")
[ -n "${ENV_USER:-}" ] && JAVA_ARGS+=(-Denv.user="$ENV_USER")
[ -n "${MODULES:-}" ] && JAVA_ARGS+=(-Dmodules="$MODULES")
[ -n "${ENV_TESTLEVEL:-}" ] && JAVA_ARGS+=(-Denv.testLevel="$ENV_TESTLEVEL")
[ -n "${CUCUMBER_FILTER_TAGS:-}" ] && JAVA_ARGS+=(-Dcucumber.filter.tags="$CUCUMBER_FILTER_TAGS")
[ -n "${RUN_ONLY_SCENARIO:-}" ] && JAVA_ARGS+=(-DrunOnlyScenario="$RUN_ONLY_SCENARIO")
[ -n "${FEATURE_FILES_TO_EXECUTE:-}" ] && JAVA_ARGS+=(-DfeatureFilesToExecute="$FEATURE_FILES_TO_EXECUTE")
[ -n "${JAVA_EXTRA_OPTS:-}" ] && JAVA_ARGS+=($JAVA_EXTRA_OPTS)

echo "Launching: java ${JAVA_ARGS[*]} -jar uitest-esignet-*.jar"
java "${JAVA_ARGS[@]}" -jar uitest-esignet-*.jar