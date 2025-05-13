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

if [[ -d "${_previous_run_cache_dir}" ]]
then
    # cache dir exists
    :
else
    mkdir -p "${_previous_run_cache_dir}"
fi

: ${LDAP_URL:='ldap://ldap:3389'}

dsidm_cmd_to_evaluate="dsidm --basedn 'dc=planetecitroen,dc=fr' --binddn 'cn=Directory Manager' --pwdfile '/etc/pwdfile.txt' --json '${LDAP_URL}'"
ldapsearch_cmd="ldapsearch -x -b "ou=people,dc=planetecitroen,dc=fr" -H ${LDAP_URL}"

export LANG='en_US.utf8'

env


: ${CLOUD_AFFILIATED_LDAP_GROUP_NAME:='_NOT_INITILIZED_'}

addUidToAffiliatedGroup ()
{
    ldap_dn="$1"

    eval ${dsidm_cmd_to_evaluate} 'group' 'add_member' \'${CLOUD_AFFILIATED_LDAP_GROUP_NAME}\'  \'${ldap_dn}\'
    
}

getCurrentListOfUidsInAffiliatedGroup ()
{

    eval ${dsidm_cmd_to_evaluate} 'group' 'members' \'${CLOUD_AFFILIATED_LDAP_GROUP_NAME}\'
    
}

revokeServiceBoxAccess ()
{
    ldap_dn="$1"

    eval ${dsidm_cmd_to_evaluate} group remove_member \'${ALLOWING_LDAP_GROUP_NAME}\'  \'${ldap_dn}\'
}

updateCloudProfilesCacheAndStopWithKey ()
{

    key_to_search_for="$1"

    if [[ -r "${_cache_dir}/cloudMembers.json" ]]
    then
	# we already downloaded the list of cloud members
	:
    else
	curl -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" --output "${_cache_dir}/cloudMembers.json" -X GET "${CLOUD_BASE_URL}"'/ocs/v1.php/cloud/users?format=json' -H "OCS-APIRequest: true"
    fi

    jq -r '.ocs.data.users[]' "${_cache_dir}/cloudMembers.json" > "${_cache_dir}/cloudMembers.txt"

    while read cloud_uid
    do

	cloud_profile_cache_file_name="${_cache_dir}"/cloud_profile_"${cloud_uid}".json

	if [[ -r "${cloud_profile_cache_file_name}" ]]
	then
	    # we already donwloaded the data
	    :
	else

	    url_encoded_uid=$( echo -n "${cloud_uid}" | jq -sRr '@uri' )

	    curl -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" -X GET "${CLOUD_BASE_URL}"'/ocs/v1.php/cloud/users/'"${url_encoded_uid}"'?format=json' -H "OCS-APIRequest: true" | jq -r '.' > "${cloud_profile_cache_file_name}"
	fi

	if [[ -n "${key_to_search_for}" ]]
	then
	    if grep --fixed-strings "${key_to_search_for}" "${cloud_profile_cache_file_name}"
	    then
		break
	    fi
	fi

    done < "${_cache_dir}/cloudMembers.txt"

}

clearCloudProfileCacheForCloudUID ()
{
    cloud_uid="$1"

    mv -f "${_cache_dir}"/cloud_profile_"${cloud_uid}".json "${_previous_run_cache_dir}"
}

clearNonRemanentCachedFiles ()
{
    #
    # remove all cloud profile without mandatory attributes
    #
    mandatory_json_attributes="website"

    for attribute in
    do
	obsolete_cloud_profile=$( grep --files-without-match --fixed-strings "\"${attribute}\": " cloud_profile_*.json )
	for f in "${obsolete_cloud_profile}"
	do
	    mv -f "${f}" "${_previous_run_cache_dir}"
	done
    done

    mv -f "${_cache_dir}/cloudMembers.json" "${_previous_run_cache_dir}"
}


getCloudProfileUID ()
{
    invision_profile_url="$1"

    # search in cached profiles once
    cloud_profile_entries=$(
	grep --files-with-matches --fixed-strings "${invision_profile_url}" "${_cache_dir}/cloud_profile_"*.json
			 )
    if [[ -z "${cloud_profile_entries}" ]]
    then
	# not found entry
	# update the cache and try again
	updateCloudProfilesCacheAndStopWithKey "${invision_profile_url}"
    fi

    # search a second time, after cache update
    cloud_profile_entries=$(
	grep --files-with-matches --fixed-strings "${invision_profile_url}" "${_cache_dir}/cloud_profile_"*.json
			 )

    if [[ -z "${cloud_profile_entries}" ]]
    then
	# not found entry
	# no cloud uid found for forum profile url
	echo ''
	return 1
    fi

    # FIXME: we suppose that a single file name is returned
    cloud_id=$( cat "${cloud_profile_entries}" | jq -r '.ocs.data.id' )
    echo "${cloud_id}"
    return 0
}

# Get all forum members which are member of the required groups

if [[ -z "${INVISION_GROUP_ID1}" ]]
then
    echo "ERROR: INVISION_GROUP_ID1 not set" 1>&2
    exit 1
fi

_group_url_arg="group[]=${INVISION_GROUP_ID1}"

if [[ -n "${INVISION_GROUP_ID2}" ]]
then
    _group_url_arg+="&group[]=${INVISION_GROUP_ID2}"
fi

if [[ -n "${INVISION_GROUP_ID3}" ]]
then
    _group_url_arg+="&group[]=${INVISION_GROUP_ID3}"
fi

#FIXME: perPage should be a param

curl -s -u "${INVISION_API_KEY}:" --output "${_cache_dir}/forumMembersWithAccess.json" 'https://www.planete-citroen.com/api/core/members/?'"${_group_url_arg}"'&perPage=5000'

#
# Extract Invision profile URL for all found members

jq -r '.results[].profileUrl' "${_cache_dir}/forumMembersWithAccess.json" > "${_cache_dir}/forumProfiles.txt"

#FIXME: test!!
# > "${_cache_dir}/forumProfiles.txt"
# echo 'https://www.planete-citroen.com/profile/1067-bernhara/' >> "${_cache_dir}/forumProfiles.txt"
# echo 'https://www.planete-citroen.com/profile/2-nicolas/' >> "${_cache_dir}/forumProfiles.txt"
# echo 'https://www.planete-citroen.com/profile/23962-alan-ford/' > "${_cache_dir}/forumProfiles.txt"

if [[ -n "${TEST_CONTENT4_forumProfiles}" ]]
then
    echo "${TEST_CONTENT4_forumProfiles}" > "${_cache_dir}/forumProfiles.txt"
fi

#
# get current member list of affiliated group
#
getCurrentListOfUidsInAffiliatedGroup > "${_cache_dir}/affiliatedGroupMembers.json"

while read line
do
    echo "DEBUG: syncing ${line}"

    invision_profile_url="${line}"

    # get CloudProfile entries for this profile
    if cloud_id=$( getCloudProfileUID "${invision_profile_url}" )
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
	echo "INTERNAL ERROR: Could not file \"${uid}\" in ldap" 1>&2
	continue
	# NOT REACHED
    fi

    dn=$( sed -n -e '/^dn: /s/^dn: //p' <<< ${dn_search_result} )

    if grep -q --fixed-strings "${dn}" "${_cache_dir}/affiliatedGroupMembers.json"
    then
	# DN already member of affiliated group => skip
	(
	    echo "INFO: \"${dn}\" is already member of group \"${CLOUD_AFFILIATED_LDAP_GROUP_NAME}\". SKIP action."
	) 1>&2

    else
	
	addUidToAffiliatedGroup "${dn}"
	(
	    echo "INFO: \"${dn}\" is now member of group \"${CLOUD_AFFILIATED_LDAP_GROUP_NAME}\""
	) 1>&2
	# User has been updated +> clear cache information
	clearCloudProfileCacheForCloudUID "${cloud_id}"
    fi

done < "${_cache_dir}/forumProfiles.txt"

clearNonRemanentCachedFiles

exit 0
