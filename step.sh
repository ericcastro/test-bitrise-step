#!/usr/bin/env bash

set -ex
shopt -s nocasematch

# Results and Upload API client functions

get_scan_status() {
    # Fetch scan status:
    #   - The output on stdout is the HTTP status (200 on success);
    #   - The output in temp/issues is the HTTP response body.

    curl                                                       \
        --header "Authorization: APIKey ${dt_results_api_key}" \
        --output "${temp}/status"                              \
        --request GET                                          \
        --silent                                               \
        --write-out '%{http_code}'                             \
        "https://api.securetheorem.com/apis/mobile_security/results/v2/mobile_apps/${1}/scans/${2}"
}

get_security_findings() {
    local severity

    # Fetch security findings:
    #   - The output on stdout is the HTTP status (200 on success);
    #   - The output in temp/issues is the HTTP response body.

    read -a severity -r <<< "${@:2}"

    curl                                                       \
        ${severity[@]/#/--url-query severity=}                 \
        --header "Authorization: APIKey ${dt_results_api_key}" \
        --output "${temp}/issues"                              \
        --request GET                                          \
        --silent                                               \
        --url-query "mobile_app_id=${1}"                       \
        --url-query "status_group=OPEN"                        \
        --write-out '%{http_code}'                             \
        "https://api.securetheorem.com/apis/mobile_security/results/v2/security_findings"
}

upload_app_build() {
    local sourcemap

    # Check parameters

    if [ ! -f "${1}" ]
    then
        printf 'App binary file not found\n' >&2
        return 1
    fi

    if [ ! -z "${2}" ] && [ ! -f "${2}" ]
    then
        printf 'Sourcemap file not found\n' >&2
        return 1
    fi

    # Perform upload:
    #   - The output on stdout is the HTTP status (200 on success);
    #   - The output in temp/upload is the HTTP response body.

    read -a sourcemap -r <<< "${@:2}"

    curl                                                      \
        ${sourcemap[@]/#/--form sourcemap=@}                  \
        --form "file=@${1}"                                   \
        --header "Authorization: APIKey ${dt_upload_api_key}" \
        --output "${temp}/upload"                             \
        --request POST                                        \
        --silent                                              \
        --write-out '%{http_code}'                            \
        'https://prod-dopinder-v2.securetheorem.com/api/v1/upload/application/upload'
}

# Script actions

perform_block_on_severity() {
    local http_status issues_count issues_found

    # Check required environment variables

    if [ -z "${dt_results_api_key}" ]
    then
        printf 'Missing environment variable: dt_results_api_key\n' >&2
        return 1
    fi

    if [[ "${dt_results_api_key}" =~ APIKey* ]]
    then
        printf 'dt_results_api_key should not start with "APIKey"\n' >&2
        return 1
    fi

    # Wait until scan are completed

    if ! wait_for_scan_completion "${1}" "${2}"
    then
        printf 'Failed to fetch scan status\n' >&2
        return 1
    fi

    # Get security issues

    http_status=$(get_security_findings "${1}" "${@:3}")

    # If the previous request failed, show an error on stderr, and fail.

    case "${http_status}" in
        '200')
            issues_count=$(
                jq < "${temp}/issues" \
                    --raw-output      \
                    '.pagination_information.total_count'
            )
            issues_found=$(
                jq < "${temp}/issues" \
                    --raw-output      \
                    '.security_findings'
            )
        ;;
        *)
            printf 'Failure while getting security findings\n' >&2
            printf 'HTTP status was: %s\n' "${http_status}" >&2
            printf 'HTTP response was:\n' >&2
            cat "${temp}/issues" >&2
            return 1
        ;;
    esac

    # Check security issues

    case "${issues_count}" in
        '0')
            printf 'No security issues detected.\n'
        ;;
        *)
            printf 'Security issues detected: %s\n' "${issues_found}"
            return 1
        ;;
    esac
}

perform_upload_app_build() {
    # Check required environment variables

    if [ -z "${dt_upload_api_key}" ]
    then
        printf 'Missing environment variable: dt_upload_api_key\n' >&2
        return 1
    fi

    if [[ "${dt_upload_api_key}" =~ APIKey* ]]
    then
        printf 'dt_upload_api_key should not start with "APIKey"\n' >&2
        return 1
    fi

    if [ -z "${file_path}" ]
    then
        printf 'Missing environment variable: file_path\n' >&2
        return 1
    fi

    # Perform upload

    upload_app_build "${file_path}" "${sourcemap:-}"
}

wait_for_scan_completion() {
    for _ in {0..60}
    do
        case $(get_scan_status "${1}" "${2}") in
            '200')
                scan_dynamic=$(
                    jq < "${temp}/status" \
                        --raw-output      \
                        '.dynamic_scan.status'
                )
                scan_static=$(
                    jq < "${temp}/status" \
                        --raw-output      \
                        '.static_scan.status'
                )
            ;;
            *)
                return 1
            ;;
        esac

        case "${scan_dynamic}" in
            'CANCELLED'|'FAILED')
                printf 'Scan %s failed, skipping vulnerability check\n' "${2}" >&2
                return 1
            ;;
            'COMPLETED'|'SCAN_ATTEMPT_ERROR')
                printf 'Scan %s: Dynamic scans done\n' "${2}"
            ;;
            *)
                sleep 10
                continue
            ;;
        esac

        case "${scan_static}" in
            'CANCELLED'|'FAILED'|'SCAN_ATTEMPT_ERROR')
                printf 'Scan %s failed, skipping vulnerability check\n' "${2}" >&2
                return 1
            ;;
            'COMPLETED')
                printf 'Scan %s: Static scans done\n' "${2}"
            ;;
            *)
                sleep 10
                continue
            ;;
        esac

        return
    done
}

# Script logic

temp=$(mktemp --directory)
trap 'rm -r "${temp}"' EXIT

http_status=$(perform_upload_app_build)

# If the previous request failed, show an error on stderr, and fail.

case "${http_status}" in
    '200')
        build_scan_id=$(jq '.scan_id' < "${temp}/upload")
        mobile_app_id=$(jq '.mobile_app_id' < "${temp}/upload")
    ;;
    *)
        printf 'Failure while uploading the build\n' >&2
        printf 'HTTP status was: %s\n' "${http_status}" >&2
        printf 'HTTP response was:\n' >&2
        cat "${temp}/upload" >&2
        exit 1
    ;;
esac

case "${BLOCK_ON_SEVERITY}" in
    'HIGH')
        severity=('HIGH')
        perform_block_on_severity "${mobile_app_id}" "${build_scan_id}" "${severity[@]}"
    ;;
    'MEDIUM')
        severity=('MEDIUM' 'HIGH')
        perform_block_on_severity "${mobile_app_id}" "${build_scan_id}" "${severity[@]}"
    ;;
    'LOW')
        severity=('LOW' 'MEDIUM' 'HIGH')
        perform_block_on_severity "${mobile_app_id}" "${build_scan_id}" "${severity[@]}"
    ;;
    '')
        printf 'BLOCK_ON_SEVERITY is not set. Skipping vulnerability check.\n'
    ;;
    *)
        printf 'Invalid severity in BLOCK_ON_SEVERITY\n' >&2
        exit 1
    ;;
esac
