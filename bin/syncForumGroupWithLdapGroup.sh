#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

if [[ -n "${SHELL_DEBUG}" ]]
then
    set -x
fi

: ${LDAP_URL:='ldap://ldap:3389'}

dsidm_cmd_to_evaluate="dsidm --basedn 'dc=planetecitroen,dc=fr' --binddn 'cn=Directory Manager' --pwdfile '/etc/pwdfile.txt' --json '${LDAP_URL}'"
ldapsearch_cmd="ldapsearch -x -b "ou=people,dc=planetecitroen,dc=fr" -H ${LDAP_URL}"

export LANG='en_US.utf8'

if [[ -n "${SHELL_DEBUG}" ]]
then
    env
    set -x
fi

Usage ()
{
    echo "Usage: $( basename "$0" ) <Invision group ID> <Cloud LDAP group name>
	- all members of <Invision group ID> are added to <Cloud LDAP group name>
	- members of <Cloud LDAP group name> not in <Invision group ID> are remove from <Cloud LDAP group name>" 1>&2
}


INVISION_SOURCE_GROUP_ID_TO_SYNC="$1"
CLOUD_LDAP_GROUP_NAME_TO_SYNC="$2"

if [[ -z "${INVISION_SOURCE_GROUP_ID_TO_SYNC}" ]]
then
    Usage
    exit 1
fi

if [[ -z "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}" ]]
then
    Usage
    exit 1
fi

_cache_dir="/var/cache4sync/${INVISION_SOURCE_GROUP_ID_TO_SYNC}"
_previous_run_cache_dir="${_cache_dir}/previous_run"

if [[ -z "${CURL_EXTRA_ARGs}" ]]
then
    CURL='curl'
else
    CURL="curl ${CURL_EXTRA_ARGs}"
fi

_TMP_REMAP_CLOUD_UID_TO_LDAP_CN ()
{
    cloud_uid="$1"

    # FIXME: inconsistency between Cloud & Ldap => uid mismatch
    # remap Cloud uids to the corresponding Ldap dn

    case "${cloud_uid}" in
	'8e198ee0-d5b3-46fa-be8e-f2b36402b433')
	    cloud_uid='pc_forum_sso-36979'
	    ;;
	'de2c9397-d5e9-49ed-a2b7-a6ad2673f3da')
	    cloud_uid='pc_forum_sso-7212'
	    ;;
    esac

    echo "${cloud_uid}"
}


addUidToCloudGroup ()
{
    cloud_uid="$1"

    # FIXME: inconsistency between Cloud & Ldap => uid mismatch
    remapped_cloud_uid=$( _TMP_REMAP_CLOUD_UID_TO_LDAP_CN "${cloud_uid}" )
    cloud_uid="${remapped_cloud_uid}"

    dn=$( eval ${dsidm_cmd_to_evaluate} user get \'${cloud_uid}\' | jq -r '.dn' )
    if [[ -z "${dn}" ]]
    then
	echo "ERROR: could not get DN for uid \"${cloud_uid}\" from Ldap" 1>&2
    else
	eval ${dsidm_cmd_to_evaluate} 'group' 'add_member' \'${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\'  \'${dn}\'
    fi
}

removeUidFromCloudGroup ()
{
    cloud_uid="$1"

    # FIXME: inconsistency between Cloud & Ldap => uid mismatch
    remapped_cloud_uid=$( _TMP_REMAP_CLOUD_UID_TO_LDAP_CN "${cloud_uid}" )
    cloud_uid="${remapped_cloud_uid}"

    dn=$( eval ${dsidm_cmd_to_evaluate} user get \'${cloud_uid}\' | jq -r '.dn' )

    eval ${dsidm_cmd_to_evaluate} 'group' 'remove_member' \'${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\'  \'${dn}\'
}

getCurrentListOfUidsInCloudGroupToSync ()
{
    # NOTICE: equivalent call to OCS NextCLoud call is very slow 
    cloud_group_cn="$1"

    cloud_uids=$( eval ${dsidm_cmd_to_evaluate} group members \'${cloud_group_cn}\' | jq -r '.members[]' )

    #FIXME: this iteration is very slow.
    # may be replaced by sed
    while read -r cn
    do
	if [[ -n "${cn}" ]]
	then
	    eval ${dsidm_cmd_to_evaluate} user get_dn \'${cn}\' |  jq -r '.attrs.uid[]'
	fi
    done <<< "${cloud_uids}"
}

fetchDataForValidCloudId ()
{
    # FIXME:
    # this function assumes that cloud_uid is a valid and existing Cloud id
    cloud_uid="$1"

    url_encoded_uid=$( echo -n "${cloud_uid}" | jq -sRr '@uri' )
    
    _json_decode_curl_out=$( ${CURL} -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" -X GET "${CLOUD_BASE_URL}"'/ocs/v2.php/cloud/users/'"${url_encoded_uid}"'?format=json' -H "OCS-APIRequest: true" | jq -r '.' )
    echo "${_json_decode_curl_out}"
}

getAndUpdateCacheForSingleCloudUid ()
{

    cloud_uid="$1"

    cloud_profile_dump_file_name="${_cache_dir}"/cloud_profile_"${cloud_uid}".json

    if [[ -r "${cloud_profile_dump_file_name}" ]]
    then
	# we already donwloaded the data
	:
    else
	fetchDataForValidCloudId "${cloud_uid}"  > "${cloud_profile_dump_file_name}"
    fi

    cat "${cloud_profile_dump_file_name}"
}

updateDumpForListOfloudUid ()
{

    file_of_cloud_uids="$1"

    while read -r cloud_uid
    do
	cloud_user_data=$( getAndUpdateCacheForSingleCloudUid "${cloud_uid}" )
    done < "${file_of_cloud_uids}"
}

_outdateCloudUidDumpData () {

    cloud_uid="$1"

    cache_file="${_cache_dir}/cloud_profile_${cloud_uid}.json"

    if [[ -r "${cache_file}" ]]
    then
	if [[ -d "${_previous_run_cache_dir}" ]]
	then
	    mv -f "${cache_file}" "${_previous_run_cache_dir}"
	else
	    rm -f "${cache_file}"
	fi
    fi
}

ignoreDisabledCloudUidsAndUpdateDump ()
{
    #FIXME: first arg no more used
    cloud_uids_file="$1"
    active_cloud_uids_file="$2"

    disabled_profiles_uid_list=$( jq -s . "${_cache_dir}"/cloud_profile_*.json | jq -r '.[].ocs.data | select(.enabled==false) | .id' )

    while read -r cloud_uid
    do
	if [[ -n "${cloud_uid}" ]]
	then
	    _outdateCloudUidDumpData "${cloud_uid}"
	fi
    done <<<"${disabled_profiles_uid_list}"

    enabled_profiles_uid_list=$( jq -s . "${_cache_dir}"/cloud_profile_*.json | jq -r '.[].ocs.data | select(.enabled==true) | .id' )
    echo "${enabled_profiles_uid_list}" >"${active_cloud_uids_file}"
}

_initCache ()
{

    if [[ -d "${_cache_dir}" ]]
    then
	# cache dir exists
	:
    else
	mkdir -p "${_cache_dir}"
    fi

    if [[ -d "${_previous_run_cache_dir}" ]]
    then
	# cache dir exists
	:
    else
	mkdir -p "${_previous_run_cache_dir}"
    fi

    # deleted outdate files
    # FIXME: 15 should be param
    find "${_cache_dir}" -maxdepth 0 -mtime +15 -exec rm {} \;
}

_safeDeleteCachedFileList ()
{
    multiline_file_list="$1"
    if [[ -n "${multiline_file_list}" ]]
    then
	while read -r obsolete_file
	do
	    if [[ -f "${obsolete_file}" ]]
	    then
		mv "${obsolete_file}" "${_previous_run_cache_dir}"
	    fi
	done <<< "${multiline_file_list}" 
    fi
}

_clearNonRemanentAndObsoleteCachedFiles ()
{
    # FIXME: is this still necessary???

    matched=$( grep --files-with-match --fixed-strings '"website": ""' "${_cache_dir}"/cloud_profile_*.json )
    _safeDeleteCachedFileList "${matched}"

    matched=$( grep --files-without-match --fixed-strings '"website":' "${_cache_dir}"/cloud_profile_*.json )
    _safeDeleteCachedFileList "${matched}"
    
    matched=$( grep --files-with-match --fixed-strings '"enabled": false' "${_cache_dir}"/cloud_profile_*.json )
    _safeDeleteCachedFileList "${matched}"
}


joinCloudSSOProfileWithInvisionProfile ()
{
    # WARNING!
    #
    # we assume the this profile has been created by SSO => it has the form "pc_forum_sso-<invision_profile_UID>"

    cloud_id="$1"
    invision_profile_url="$2"
    invision_profile_uid="$3"

    _curlResult=$(
	${CURL} \
	    -s \
	    -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" \
	    -H 'Content-Type: application/json' \
	    -H 'Accept: application/json, text/plain, */*' \
	    -H 'OCS-APIRequest: true' \
	    -X PUT \
	    --data '{"key":"website","value":"'${invision_profile_url}'"}' \
	    "${CLOUD_BASE_URL}"'/ocs/v2.php/cloud/users/'"${cloud_id}"
	)

    # cache file, if exists, is incorrect
    clearCloudProfileCacheForCloudUID "${cloud_id}"

}

searchOrMayBeUpdateTheCorrespondingCloudProfileUID ()
{
    invision_profile_url="$1"

    cloud_profile_entries=''
    
    cloud_profile_entries=$(
	grep --files-with-matches --fixed-strings "\"${invision_profile_url}\"" "${_cache_dir}/cloud_profile_"*.json
			 )

    #
    # Consistency check: verify that only 1 line has been return
    #
    cloud_profile_file=''
    if [[ -n "${cloud_profile_entries}" ]]
    then
	nb_matches=$( echo "${cloud_profile_entries}" | wc -l )
	if [[ "${nb_matches}" -eq 1 ]]
	then
	    cloud_profile_file="${cloud_profile_entries}"
	else
	    #
	    # INCONSITENCY: we got multiple lines =>
	    #    more than one Cloud profile with the same Forum profile
	    #
	    # Warn and use the first line only
	    echo "WARNING: Forum profile \"${invision_profile_url}\" is associated to Cloud more that one Cloud user:" 1>&2
	    echo "${cloud_profile_entries}" 1>&2

	    cloud_profile_file=$( echo "${cloud_profile_entries}" | head -1 )
	    echo "	Consider only data in file ${cloud_profile_file}" 1>&2

	    # forget remaining file
	    ignored_files=$( echo "${cloud_profile_entries}" | tail --lines=+2 )
	    while read -r filename
	    do
		rm "${filename}"
	    done <<< "${ignored_files}"

	fi
    fi

    if [[ -z "${cloud_profile_file}" ]]
    then
	# searched entry not found
	# => no Cloud user has ${invision_profile_url} url as attribute

	#
	# SSO special case
	# ================
	#
	# Try to correct behind the scene for SSO Cloud profiles

	# if a SSO user exists, it has the form "pc_forum_sso-<Invision UID>"

	invision_profile_uid=$( echo "${invision_profile_url}" | sed -n 's|.*/profile/\([1-9][0-9]\+\)-.*|\1|p' )
	cloud_sso_id_to_search_for="pc_forum_sso-${invision_profile_uid}"
	
	# search for such a user with UID ${cloud_sso_id_to_search_for}
	cloud_ocs_request_statuscode=$( ${CURL} -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" -X GET "${CLOUD_BASE_URL}"'/ocs/v2.php/cloud/users/'"${cloud_sso_id_to_search_for}"'?format=json' -H "OCS-APIRequest: true" | jq -r '.ocs.meta.statuscode' )
	if [[ "${cloud_ocs_request_statuscode}" == '200' ]]
	then
	    # The searched SSO user exists
	    cloud_sso_id=${cloud_sso_id_to_search_for}

	    # NOW have to update "website" attribute
	    joinCloudSSOProfileWithInvisionProfile "${cloud_sso_id}" "${invision_profile_url}" "${invision_profile_uid}"
	    
	    # and then update cache file
	    cloud_profile_dump_file_name="${_cache_dir}"/cloud_profile_"${cloud_sso_id}".json
	    _outdateCloudUidDumpData "${cloud_sso_id}"
	    getAndUpdateCacheForSingleCloudUid "${cloud_sso_id}" > /dev/null

	    # this is the file we searched for
	    cloud_profile_file=${cloud_profile_dump_file_name}
	fi
    fi

    if [[ -z "${cloud_profile_entries}" ]]
    then
	echo ''
	return 1
    else
	cloud_id=$( cat "${cloud_profile_file}" | jq -r '.ocs.data.id' )
	echo "${cloud_id}"
	return 0
    fi
}

#============================================================================================

#
# Main
# ====

_initCache

#
# Init datas
#

#
# Cloud data
# ==========

# since we must process all cloud uids, first fetch and uddate cache for all cloud uids
${CURL} -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" -X GET "${CLOUD_BASE_URL}"'/ocs/v2.php/cloud/users?format=json' -H "OCS-APIRequest: true" \
    | jq -r '.ocs.data.users[]' > "${_cache_dir}/cloudAllUIDs.txt"

updateDumpForListOfloudUid "${_cache_dir}/cloudAllUIDs.txt"

ignoreDisabledCloudUidsAndUpdateDump "${_cache_dir}/cloudAllUIDs.txt" "${_cache_dir}/cloudActiveUIDs.txt"

#
# Cloud data
# ==========

_group_url_arg="group[]=${INVISION_SOURCE_GROUP_ID_TO_SYNC}"

# get all Forum members belonging to INVISION_SOURCE_GROUP_ID_TO_SYNC
#FIXME: perPage should be a param

${CURL} -s -u "${INVISION_API_KEY}:" --output "${_cache_dir}/forumMembersInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}.json" 'https://www.planete-citroen.com/api/core/members/?'"${_group_url_arg}"'&perPage=5000'

#
# buils working data
# ==================

#
# Extract Invision profile URL for all found members
# --------------------------------------------------
#

jq -r '.results[].profileUrl' "${_cache_dir}/forumMembersInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}.json" > "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}.txt"

while read -r invision_profile_url
do
    cloud_uid=$( searchOrMayBeUpdateTheCorrespondingCloudProfileUID "${invision_profile_url}" )

    if [[ -z "${cloud_uid}" ]]
    then
	# not corresponding cloud_uid found => unable to handle
	:
    else
	echo "${cloud_uid};${invision_profile_url}"
    fi
done \
    < "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}.txt" \
    > "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}_withCorrespondingCloudUid.txt"

#
# Cloud side data
# ---------------
#

# get corresponding Forum URL registered as Website Cloud profile attribute
while read -r cloud_uid
do
    cloud_user_data=$( getAndUpdateCacheForSingleCloudUid "${cloud_uid}" )

    website_cloud_profile_attribute=$( echo "${cloud_user_data}" | jq -r '.ocs.data.website' 2>/dev/null )
	
    if [[ -z "${website_cloud_profile_attribute}" ]]
    then
	# the attribute has not be set for this Cloud uid
	# skip this uid
	:
    else
	# keep this uid for further computation
	echo "${cloud_uid};${website_cloud_profile_attribute}"
    fi
    
done < "${_cache_dir}/cloudActiveUIDs.txt" > "${_cache_dir}/cloudUids_withCorrespondingForumProfile.txt"

#
#

# remove from this list uids without matching Forum profile information (Website attribute)

#
#FIXME: the Forum profile URL store in the Website attribute must match exactly the URL of the Forum profile
#       Mainly, the trailing '/' must be there


#
# get current member list of cloud group
#
getCurrentListOfUidsInCloudGroupToSync "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}" > "${_cache_dir}/cloudUidsInGroupToSync.txt"

cat "${_cache_dir}/cloudUidsInGroupToSync.txt" \
    "${_cache_dir}/cloudActiveUIDs.txt" \
    | sort \
    | uniq -d > "${_cache_dir}/cloudActiveUidsInGroupToSync.txt"

while read -r cloud_uid
do

    cloud_user_data=$( getAndUpdateCacheForSingleCloudUid "${cloud_uid}" )

    website_cloud_profile_attribute=$( echo "${cloud_user_data}" | jq -r '.ocs.data.website' 2>/dev/null )
    if [[ -z "${website_cloud_profile_attribute}" ]]
    then
	# the attribute has not be set for this Cloud uid
	# skip this uid
	:
    else
	# keep this uid for further computation
	echo "${cloud_uid};${website_cloud_profile_attribute}"
    fi
    
done < "${_cache_dir}/cloudActiveUidsInGroupToSync.txt" > "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt"

#
# Members of Forum group not member of Ldap group
#

cat "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt" \
    "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt" \
    "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}_withCorrespondingCloudUid.txt" \
    | sort \
    | uniq -u > "${_cache_dir}/cloudUidsToAdd.txt"

while read -r id_and_url
do
    cloud_uid="${id_and_url%;*}"

    echo "INFO: adding Cloud uid \"${cloud_uid}\" to Ldap Group \"${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\"" 1>&2
    addUidToCloudGroup "${cloud_uid}" "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}"
    _outdateCloudUidDumpData "${cloud_uid}"
    
done < "${_cache_dir}/cloudUidsToAdd.txt"

#
# Members of Ldap group not member of Forum group
#

cat "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}_withCorrespondingCloudUid.txt" \
    "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_SOURCE_GROUP_ID_TO_SYNC}_withCorrespondingCloudUid.txt" \
    "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt" \
    | sort \
    | uniq -u > "${_cache_dir}/cloudUidsToRemove.txt"

while read -r id_and_url
do
    cloud_uid="${id_and_url%;*}"

    echo "INFO: removing Cloud uid \"${cloud_uid}\" from Ldap Group \"${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\"" 1>&2
    removeUidFromCloudGroup "${cloud_uid}" "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}"
    _outdateCloudUidDumpData "${cloud_uid}"
    
done < "${_cache_dir}/cloudUidsToRemove.txt"

_clearNonRemanentAndObsoleteCachedFiles

exit 0
