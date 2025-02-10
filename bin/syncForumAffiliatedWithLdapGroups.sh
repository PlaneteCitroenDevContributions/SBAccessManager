#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

_cach_dir="/var/cache4sync"

if [[ -n "${SHELL_DEBUG}" ]]
then
    set -x
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

    eval ${dsidm_cmd_to_evaluate} 'group' 'add_member' "${CLOUD_AFFILIATED_LDAP_GROUP_NAME}"  "${ldap_dn}"
    
}

getCurrentListOfUidsInffiliatedGroup ()
{

    eval ${dsidm_cmd_to_evaluate} 'group' 'members' "${CLOUD_AFFILIATED_LDAP_GROUP_NAME}"
    
}

revokeServiceBoxAccess ()
{
    ldap_dn="$1"

    ${dsidm_cmd} group remove_member "${ALLOWING_LDAP_GROUP_NAME}"  "${ldap_dn}"
}

updateCloudProfilesCacheAndStopWithKey ()
{

    key_to_search_for="$1"

    curl -s -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" --output "${_cach_dir}/cloudMembers.json" -X GET "${CLOUD_BASE_URL}"'/ocs/v1.php/cloud/users?format=json' -H "OCS-APIRequest: true"

    jq -r '.ocs.data.users[]' "${_cach_dir}/cloudMembers.json" > "${_cach_dir}/cloudMembers.txt"

    while read cloud_uid
    do

	cloud_profile_cache_file_name="${_cach_dir}"/cloud_profile_"${cloud_uid}".json

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

    done < "${_cach_dir}/cloudMembers.txt"

}


getCloudProfileUID ()
{
    invision_profile_url="$1"

    # search in cached profiles once
    cloud_profile_entries=$(
	grep --files-with-matches --fixed-strings "${invision_profile_url}" "${_cach_dir}/cloud_profile_"*.json
			 )
    if [[ -z "${cloud_profile_entries}" ]]
    then
	# not found entry
	# update the cache and try again
	updateCloudProfilesCacheAndStopWithKey "${invision_profile_url}"
    fi

    # search a second time, after cache update
    cloud_profile_entries=$(
	grep --files-with-matches --fixed-strings "${invision_profile_url}" "${_cach_dir}/cloud_profile_"*.json
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

_group_url_arg="group=${INVISION_GROUP_ID1}"

if [[ -n "${INVISION_GROUP_ID2}" ]]
then
    _group_url_arg+=",${INVISION_GROUP_ID2}"
fi

if [[ -n "${INVISION_GROUP_ID3}" ]]
then
    _group_url_arg+=",${INVISION_GROUP_ID3}"
fi

#FIXME: perPage should be a param

curl -s -u "${INVISION_API_KEY}:" --output "${_cach_dir}/forumMembersWithAccess.json" 'https://www.planete-citroen.com/api/core/members/?'"${_group_url_arg}"'&perPage=5000'

#
# Extract Invision profile URL for all found members

jq -r '.results[].profileUrl' "${_cach_dir}/forumMembersWithAccess.json" > "${_cach_dir}/forumProfiles.txt"

#FIXME: test!!
# > "${_cach_dir}/forumProfiles.txt"
# echo 'https://www.planete-citroen.com/profile/1067-bernhara/' >> "${_cach_dir}/forumProfiles.txt"
# echo 'https://www.planete-citroen.com/profile/2-nicolas/' >> "${_cach_dir}/forumProfiles.txt"

#
# get current member list of affiliated group
#
getCurrentListOfUidsInffiliatedGroup > "${_cach_dir}/affiliatedGroupMembers.json"

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

    if grep --fixed-strings "${dn}" "${_cach_dir}/affiliatedGroupMembers.json"
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
    fi

done < "${_cach_dir}/forumProfiles.txt"

exit 0
