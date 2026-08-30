#!/bin/sh
# Generate Mudi.xcodeproj and keep the Development Team last chosen in Xcode.
set -eu
cd "$(dirname "$0")/.."
pbx="Mudi.xcodeproj/project.pbxproj"
team=""
if [ -f "$pbx" ]; then
	team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \([A-Z0-9]\{10\}\);$/\1/p' "$pbx" | head -1)
fi
xcodegen generate
if [ -n "$team" ] && [ -f "$pbx" ]; then
	awk -v team="$team" '
		/CODE_SIGN_STYLE = Automatic;/ {
			print
			print "				DEVELOPMENT_TEAM = " team ";"
			next
		}
		{ print }
	' "$pbx" >"$pbx.tmp"
	mv "$pbx.tmp" "$pbx"
fi
