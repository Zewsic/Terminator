#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
status=0

report() {
    printf '%s\n' "$1" >&2
    status=1
}

while IFS= read -r strings_file; do
    duplicates=$(sed -nE 's/^"([^"]+)"[[:space:]]*=.*/\1/p' "$strings_file" | sort | uniq -d)
    if [ -n "$duplicates" ]; then
        report "Duplicate localization keys in ${strings_file#$project_root/}:"
        printf '%s\n' "$duplicates" >&2
    fi
done <<EOF
$(find "$project_root/Packages/TerminatorKit/Sources" "$project_root/Terminator" -name Localizable.strings -type f)
EOF

if rg -n 'ui\.[A-Za-z0-9_.-]*\.view\.[0-9]+' \
    "$project_root/Packages/TerminatorKit/Sources" "$project_root/Terminator" \
    --glob '*.swift' --glob '*.strings' >&2; then
    report 'Positional localization keys are forbidden.'
fi

check_enum_keys() {
    localization_file=$1
    strings_file=$2
    while IFS= read -r key; do
        if ! grep -Fq "\"$key\" =" "$strings_file"; then
            report "Missing localization key '$key' in ${strings_file#$project_root/}"
        fi
    done <<EOF
$(sed -nE 's/^[[:space:]]*case[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$localization_file")
EOF
}

check_enum_keys "$project_root/Packages/TerminatorKit/Sources/TerminatorCore/Localization.swift" "$project_root/Packages/TerminatorKit/Sources/TerminatorCore/Resources/en.lproj/Localizable.strings"
check_enum_keys "$project_root/Packages/TerminatorKit/Sources/TerminatorFeatures/Localization.swift" "$project_root/Packages/TerminatorKit/Sources/TerminatorFeatures/Resources/en.lproj/Localizable.strings"
check_enum_keys "$project_root/Packages/TerminatorKit/Sources/TerminatorSecurity/Localization.swift" "$project_root/Packages/TerminatorKit/Sources/TerminatorSecurity/Resources/en.lproj/Localizable.strings"
check_enum_keys "$project_root/Packages/TerminatorKit/Sources/TerminatorSSH/Localization.swift" "$project_root/Packages/TerminatorKit/Sources/TerminatorSSH/Resources/en.lproj/Localizable.strings"
check_enum_keys "$project_root/Terminator/App/Localization.swift" "$project_root/Terminator/en.lproj/Localizable.strings"

ui_literal_pattern='\b(Text|Button|Label|Section|TextField|SecureField|Toggle|Picker|LabeledContent|ContentUnavailableView|navigationTitle|help|accessibilityLabel|alert)\([[:space:]]*"[A-Za-z]'
if rg -n --pcre2 "$ui_literal_pattern" \
    "$project_root/Packages/TerminatorKit/Sources/TerminatorFeatures" "$project_root/Terminator/App" \
    --glob '*.swift' >&2; then
    report 'Direct English literals in user-facing SwiftUI APIs are forbidden.'
fi

if rg -n --pcre2 'PresentedError\([^\n]*(title|message):[[:space:]]*"' \
    "$project_root/Packages/TerminatorKit/Sources" "$project_root/Terminator" \
    --glob '*.swift' >&2; then
    report 'PresentedError text must come from localization gateways.'
fi

exit "$status"
