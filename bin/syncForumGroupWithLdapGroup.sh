#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

_cache_dir="/var/cache4sync"
_previous_run_cache_dir="${_cache_dir}/previous_run"

if [[ -n "${SHELL_DEBUG}" ]]
then
    set -x
fi

if [[ -d "${_cache_dir}" ]]
then
    # cache dir exists
    :
else
    mkdir -p "${_cache_dir}"
fi

: ${LDAP_URL:='ldap://ldap:3389'}

dsidm_cmd_to_evaluate="dsidm --basedn 'dc=planetecitroen,dc=fr' --binddn 'cn=Directory Manager' --pwdfile '/etc/pwdfile.txt' --json '${LDAP_URL}'"
ldapsearch_cmd="ldapsearch -x -b "ou=people,dc=planetecitroen,dc=fr" -H ${LDAP_URL}"

export LANG='en_US.utf8'

env

Usage ()
{
    echo "Usage: ..." 1>&2
}


INVISION_GROUP_ID1="$1"
CLOUD_LDAP_GROUP_NAME_TO_SYNC="$2"

if [[ -z "${INVISION_GROUP_ID1}" ]]
then
    Usage
    exit 1
fi

if [[ -z "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}" ]]
then
    Usage
    exit 1
fi

if [[ -z "${CURL_EXTRA_ARGs}" ]]
then
    CURL='curl'
else
    CURL="curl ${CURL_EXTRA_ARGs}"
fi

addUidToCloudGroup ()
{
    cloud_uid="$1"

    dn=$( eval ${dsidm_cmd_to_evaluate} user get \'${cloud_uid}\' | jq -r '.dn' )

    eval ${dsidm_cmd_to_evaluate} 'group' 'add_member' \'${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\'  \'${dn}\'
}

removeUidFromCloudGroup ()
{
    cloud_uid="$1"
    dn=$( eval ${dsidm_cmd_to_evaluate} user get \'${cloud_uid}\' | jq -r '.dn' )

    eval ${dsidm_cmd_to_evaluate} 'group' 'remove_member' \'${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\'  \'${dn}\'
}

getCurrentListOfUidsInCloudGroupToSync ()
{
    # NOTICE: equivalent call to OCS NextCLoud call is very slow 
    cloud_group_cn="$1"

    cloud_uids=$( eval ${dsidm_cmd_to_evaluate} group members \'${cloud_group_cn}\' | jq -r '.members[]' )

    while read cn
    do
	if [[ -n "${cn}" ]]
	then
	    eval ${dsidm_cmd_to_evaluate} user get_dn \'${cn}\' |  jq -r '.attrs.uid[]'
	fi
    done <<< "${cloud_uids}"
}

getDataForValidCloudId ()
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

    cloud_profile_cache_file_name="${_cache_dir}"/cloud_profile_"${cloud_uid}".json

    if [[ -r "${cloud_profile_cache_file_name}" ]]
    then
	# we already donwloaded the data
	:
    else
	getDataForValidCloudId "${cloud_uid}"  > "${cloud_profile_cache_file_name}"
    fi

    cat "${cloud_profile_cache_file_name}"
}

updateCacheForListOfloudUid ()
{

    file_of_cloud_uids="$1"

    while read cloud_uid
    do
	getAndUpdateCacheForSingleCloudUid "${cloud_uid}" >/dev/null
    done < "${file_of_cloud_uids}"
}

OLD_clearCloudProfileCacheForCloudUID ()
{
    cloud_id="$1"

    if [[ -r "${_cache_dir}"/cloud_profile_"${cloud_id}".json ]]
    then
       # in some cases (DEBUG mode), this file may not have been generated
       mv -f "${_cache_dir}"/cloud_profile_"${cloud_id}".json "${_previous_run_cache_dir}"
    fi
}

_initCache ()
{

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

_clearNonRemanentCachedFiles ()
{
    #
    # remove all cloud profile without mandatory attributes
    #
    mandatory_json_attributes_array=( 'website' )

    for attribute in "${mandatory_json_attributes_array[@]}"
    do
	obsolete_cloud_profiles=$( grep --files-with-match --fixed-strings "\"${attribute}\": \"\"" "${_cache_dir}"/cloud_profile_*.json )
	while read obsolete_cache_filename
	do
	    if [[ -f "${obsolete_cache_filename}" ]]
	    then
		mv "${obsolete_cache_filename}" "${_previous_run_cache_dir}"
	    fi
	done <<< "${obsolete_cloud_profiles}"
    done

    if [[ -f "${_cache_dir}/cloudMembers.json" ]]
    then
	mv "${_cache_dir}/cloudMembers.json" "${_previous_run_cache_dir}"
    fi
}

_outdateCloudUidCacheDate () {

    cloud_uid="$1"

    rm -f "${_cache_dir}/cloud_profile_${cloud_uid}.json"
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
	grep --files-with-matches --fixed-strings "${invision_profile_url}" "${_cache_dir}/cloud_profile_"*.json
			 )

    if [[ -z "${cloud_profile_entries}" ]]
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
	
	# search for seach a user with UID ${cloud_sso_id_to_search_for}
	cloud_ocs_request_statuscode=$( ${CURL} -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" -X GET "${CLOUD_BASE_URL}"'/ocs/v2.php/cloud/users/'"${cloud_sso_id_to_search_for}"'?format=json' -H "OCS-APIRequest: true" | jq -r '.ocs.meta.statuscode' )
	if [[ "${cloud_ocs_request_statuscode}" == '200' ]]
	then
	    # The searched SSO user exists
	    cloud_sso_id=${cloud_sso_id_to_search_for}

	    # NOW have to update "website" attribute
	    joinCloudSSOProfileWithInvisionProfile "${cloud_sso_id}" "${invision_profile_url}" "${invision_profile_uid}"
	    
	    # and then update cache file
	    cloud_profile_cache_file_name="${_cache_dir}"/cloud_profile_"${cloud_sso_id}".json
	    _outdateCloudUidCacheDate "${cloud_sso_id}"
	    getAndUpdateCacheForSingleCloudUid "${cloud_sso_id}" > /dev/null

	    # this is the file we searched for
	    cloud_profile_entries=${cloud_profile_cache_file_name}
	fi
    fi

    # FIXME: we suppose that a single file name is returned
    if [[ -z "${cloud_profile_entries}" ]]
    then
	echo ''
	return 1
    else
	cloud_id=$( cat "${cloud_profile_entries}" | jq -r '.ocs.data.id' )
	echo "${cloud_id}"
	return 0
    fi
}

#
# Main
# ====

_initCache

# since we must process all cloud uids, first fetch and uddate cache for all cloud uids
${CURL} -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" -X GET "${CLOUD_BASE_URL}"'/ocs/v2.php/cloud/users?format=json' -H "OCS-APIRequest: true" \
    | jq -r '.ocs.data.users[]' > "${_cache_dir}/cloudAllUIDs.txt"

updateCacheForListOfloudUid "${_cache_dir}/cloudAllUIDs.txt"

#
# Invision side data
#

_group_url_arg="group[]=${INVISION_GROUP_ID1}"

# get all Forum members belonging to INVISION_GROUP_ID1
#FIXME: perPage should be a param

${CURL} -s -u "${INVISION_API_KEY}:" --output "${_cache_dir}/forumMembersInGroup_${INVISION_GROUP_ID1}.json" 'https://www.planete-citroen.com/api/core/members/?'"${_group_url_arg}"'&perPage=5000'

#
# Extract Invision profile URL for all found members
# --------------------------------------------------
#

jq -r '.results[].profileUrl' "${_cache_dir}/forumMembersInGroup_${INVISION_GROUP_ID1}.json" > "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_GROUP_ID1}.txt"

while read invision_profile_url
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
    < "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_GROUP_ID1}.txt" \
    > "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_GROUP_ID1}_withCorrespondingCloudUid.txt"

#
# Cloud side data
# ---------------
#

# get correspondig Forum URL registered as Website Cloud profile attribute
while read cloud_uid
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
    
done < "${_cache_dir}/cloudAllUIDs.txt" > "${_cache_dir}/cloudUids_withCorrespondingForumProfile.txt"

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

while read cloud_uid
do
    cloud_user_data=$( getAndUpdateCacheForSingleCloudUid "${cloud_uid}" )

    website_cloud_profile_attribute=$( echo "${cloud_user_data}" | jq -r '.ocs.data.website' "${cloud_profile_cache_file_name}" 2>/dev/null )
    if [[ -z "${website_cloud_profile_attribute}" ]]
    then
	# the attribute has not be set for this Cloud uid
	# skip this uid
	:
    else
	# keep this uid for further computation
	echo "${cloud_uid};${website_cloud_profile_attribute}"
    fi
    
done < "${_cache_dir}/cloudUidsInGroupToSync.txt" > "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt"

#
# Members of Forum group not member of Ldap group
#

cat "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt" \
    "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt" \
    "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_GROUP_ID1}_withCorrespondingCloudUid.txt" \
    | sort \
    | uniq -u > "${_cache_dir}/cloudUidsToAdd.txt"

while read id_and_url
do
    cloud_uid="${id_and_url%;*}"

    echo "INFO: adding Cloud uid \"${cloud_uid}\" to Ldap Group \"${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\"" 1>&2
    addUidToCloudGroup "${cloud_uid}" "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}"
    _outdateCloudUidCacheDate "${cloud_uid}"
    
done < "${_cache_dir}/cloudUidsToAdd.txt"
echo "ADD LIST"
cat "${_cache_dir}/cloudUidsToAdd.txt"

exit 1

#
# Members of Ldap group not member of Forum group
#

cat "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_GROUP_ID1}_withCorrespondingCloudUid.txt" \
    "${_cache_dir}/forumMembersProfileURLInGroup_${INVISION_GROUP_ID1}_withCorrespondingCloudUid.txt" \
    "${_cache_dir}/cloudUidsInGroupToSync_withCorrespondingForumProfile.txt" \
    | sort \
    | uniq -u > "${_cache_dir}/cloudUidsToRemove.txt"

while read id_and_url
do
    cloud_uid="${id_and_url%;*}"

    echo "INFO: removing Cloud uid \"${cloud_uid}\" from Ldap Group \"${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\"" 1>&2
    removeUidFromCloudGroup "${cloud_uid}" "${CLOUD_LDAP_GROUP_NAME_TO_SYNC}"
    _outdateCloudUidCacheDate "${cloud_uid}"
    
done < "${_cache_dir}/cloudUidsToRemove.txt"
echo "REMOVE LIST"
cat "${_cache_dir}/cloudUidsToRemove.txt"

exit 1

========================================

while read line
do
    echo "DEBUG: syncing ${line}" 1>&2

    invision_profile_url="${line}"

    # get CloudProfile entries for this profile
    if cloud_id=$( searchOrMayBeUpdateTheCloudProfileUID "${invision_profile_url}" )
    then
	:
    else
	# could not get a cloud ID for the forum profile
	echo "WARNING: no Cloud profile found for Forum profile ${invision_profile_url}"
	continue
    fi

    # retrieve user description (dn + mail) in LDAP, based on his email address (mailto)
    dn_search_result=$(
	${ldapsearch_cmd} -z 1 "uid=${cloud_id}" dn mail
    )
    if grep -q '--regexp=^dn:' <<< ${dn_search_result}
    then
	# ldap search result OK
	:
    else
	echo "INTERNAL ERROR: Could not find \"${cloud_id}\" in ldap while searching for Invision porfile ${invision_profile_url}" 1>&2
	echo "	Ldap search result: ${dn_search_result}" 1>&2

	# May be the user does not exist anymore
	# remove cached information about this user
	clearCloudProfileCacheForCloudUID "${cloud_id}"

	continue
	# NOT REACHED
    fi

    if grep -q --fixed-strings "${cloud_id}" "${_cache_dir}/cloudGroupMembers.txt"
    then
	# DN already member of cloud group => skip
	(
	    echo "INFO: \"${cloud_id}\" is already member of group \"${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\". SKIP action."
	) 1>&2

    else
	
	dn=$( sed -n -e '/^dn: /s/^dn: //p' <<< ${dn_search_result} )
	addUidToCloudGroup "${dn}"
	(
	    echo "INFO: \"${cloud_id}\" is now member of group \"${CLOUD_LDAP_GROUP_NAME_TO_SYNC}\""
	) 1>&2
	# User has been updated +> clear cache information
	clearCloudProfileCacheForCloudUID "${cloud_id}"
    fi

done < "${_cache_dir}/URLsOfForumMembersProfileInGroup_${INVISION_GROUP_ID1}.txt"

_clearNonRemanentCachedFiles

exit 0
