#!/bin/bash

set -ex
shopt -s nocasematch

# Check required environment variables
if [ -z "${dt_upload_api_key}" ]
then
    printf 'Missing input: dt_upload_api_key\n' >&2
    exit 1
elif [[ ${dt_upload_api_key} =~ APIKey* ]]
then
    printf 'Variable dt_upload_api_key should not start with "APIKey"\n' >&2
    exit 1
fi

if [ -z "${file_path}" ]
then
    printf 'Missing input: file_path\n' >&2
    exit 1
elif [ ! -f "${file_path}" ]
then
    printf 'App binary file not found\n' >&2
    exit 1
fi

sourcemap_field=""
if [ ! -z "${sourcemap}" ]
then
    sourcemap_field="--form sourcemap=@${sourcemap}"
fi

tempfile="$(mktemp)"
trap 'rm "${tempfile}"' EXIT

max_retries=3
for (( retry = 0; retry < max_retries; retry++ ))
do
    # Step 1: get the upload URL
    printf 'Generating an unique upload URL\n'

    # Create a session:
    #   - The output on stdout is the HTTP status (200 on success);
    #   - The output in tempfile is the HTTP response body.
    http_status="$(
        curl                                                      \
            --data ''                                             \
            --header "Authorization: APIKey ${dt_upload_api_key}" \
            --output "${tempfile}"                                \
            --request POST                                        \
            --silent                                              \
            --write-out '%{http_code}'                            \
            'https://api.securetheorem.com/uploadapi/v1/upload_init'
    )"

    # If the previous request failed, show an error on stdout, and retry.
    if [ "${http_status}" -ne 200 ]
    then
        printf '[%s] Failure while getting the upload URL\n' "${retry}" >&2
        printf '[%s] HTTP status was: %s\n' "${retry}" "${http_status}" >&2
        printf '[%s] HTTP response was:\n' "${retry}" >&2
        cat "${tempfile}" >&2
        continue
    fi

    # Get the upload URL from the response
    upload_url=$(jq -r '.upload_url' < "${tempfile}")
    printf '%s\n' "${upload_url}"

    # Step 2: upload the app build
    printf 'Uploading app build to Data Theorem\n'

    # Perform the upload:
    #   - The output on stdout is the HTTP status (200 on success);
    #   - The output in tempfile is the HTTP response body.
    http_status="$(
        curl                            \
            --form "file=@${file_path}" \
            ${sourcemap_field}          \
            --output "${tempfile}"      \
            --silent                    \
            --write-out '%{http_code}'  \
            "${upload_url}"
    )"

    # If the previous request failed, show an error on stdout, and retry.
    if [ "${http_status}" -ne 200 ]
    then
        printf '[%s] Failure while uploading the build\n' "${retry}" >&2
        printf '[%s] HTTP status was: %s\n' "${retry}" "${http_status}" >&2
        printf '[%s] HTTP response was:\n' "${retry}" >&2
        cat "${tempfile}" >&2
        continue
    fi

    # On success, break the loop
    break
done

if [ "${retry}" -ge "${max_retries}" ]
then
    printf 'Upload failed after %s attempts\n' "${max_retries}"
    exit 1
fi
