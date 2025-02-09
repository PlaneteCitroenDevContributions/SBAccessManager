#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

_cach_dir="/var/cache4sync"

if [[ -n "${SHELL_DEBUG}" ]]
then
    set -x
fi

dsidm_cmd="dsidm --pwdfile /etc/pwdfile.txt pcds"
ldapsearch_cmd="ldapsearch -x -b ou=people,dc=planetecitroen,dc=fr -H ldap://ldap:3389"

export LANG='en_US.utf8'

env


: ${CLOUD_AFFILIATED_LDAP_GROUP_NAME:='_NOT_INITILIZED_'}

grantServiceBoxAccess ()
{
    ldap_dn="$1"

    ${dsidm_cmd} group add_member "${ALLOWING_LDAP_GROUP_NAME}"  "${ldap_dn}"
    
}

revokeServiceBoxAccess ()
{
    ldap_dn="$1"

    ${dsidm_cmd} group remove_member "${ALLOWING_LDAP_GROUP_NAME}"  "${ldap_dn}"
}

updateCloudProfilesCacheAndStopWithKey ()
{

    key_to_search_for="$1"

    curl -u "${CLOUD_ADMIN_USER}:${CLOUD_ADMIN_PASSWORD}" --output "${_cach_dir}/cloudMembers.json" -X GET "${CLOUD_BASE_URL}"'/ocs/v1.php/cloud/users?format=json' -H "OCS-APIRequest: true"

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

curl -u "${INVISION_API_KEY}:" --output "${_cach_dir}/forumMembersWithAccess.json" 'https://www.planete-citroen.com/api/core/members/?'"${_group_url_arg}"'&perPage=5000'

#
# Extract Invision profile URL for all found members

jq -r '.results[].profileUrl' "${_cach_dir}/forumMembersWithAccess.json" > "${_cach_dir}/forumProfiles.txt"

#FIXME: test!!
echo 'https://www.planete-citroen.com/profile/1067-bernhara/' > "${_cach_dir}/forumProfiles.txt"

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
    if grep -q '--regexp=^mail:' <<< ${dn_search_result}
    then
	# ldap search result OK
	:
    else
	echo "INTERNAL ERROR: Could not file \"${uid}\" in ldap" 1>&2
	continue
	# NOT REACHED
    fi

    break
    
done < "${_cach_dir}/forumProfiles.txt"
exit 1


#
# search for all users who reserved
#

declare -a appointed_DNs_array=()

    organizer_line=$(
	echo "${vcal_data}" | grep -e '^ORGANIZER;'
		  )

    organizer_data=$(
	echo "${organizer_line}" | sed -e 's/ORGANIZER;//' -e 's/\r$//'
	     )

    displayName=$( echo "${organizer_data}" | sed -e 's/CN=\(.*\):mailto:.*$/\1/' )
    mailto=$( echo "${organizer_data}" | sed -e 's/.*:mailto:\(.*\)$/\1/' )

    (
	echo "INFO: found appointment for display Name \"${displayName}\" with email \"${mailto}\""
    ) 1>&2

    # retrieve user description (dn + mail) in LDAP, based on his email address (mailto)
    dn_search_result=$(
	${ldapsearch_cmd} -z 1 "mail=${mailto}" dn mail
    )
    if grep -q '--regexp=^mail:' <<< ${dn_search_result}
    then
	# ldap search result OK
	:
    else
	echo "INTERNAL ERROR: Could not file \"${mailto}\" in ldap" 1>&2
	continue
	# NOT REACHED
    fi

    #
    # for security, we check that the retrieved mail is what we searched for
    #
    ldap_mail=$( sed -n -e '/^mail: /s/^mail: //p' <<< ${dn_search_result} )
    lowercase_mailto=$( tr '[:upper:]' '[:lower:]' <<< ${mailto} )
    lowercase_ldap_mail=$( tr '[:upper:]' '[:lower:]' <<< ${ldap_mail} )
    if [[ "${lowercase_mailto}" != "${lowercase_ldap_mail}" ]]
    then
	echo "INTERNAL ERROR: Searched for \"${mailto}\" and found \"${ldap_mail}\" in ldap.
Strings \"${lowercase_mailto}\" and \"${lowercase_ldap_mail}\" dos not match" 1>&2
	continue
	# NOT REACHED
    fi
    
    dn=$( sed -n -e '/^dn: /s/^dn: //p' <<< ${dn_search_result} )

    appointed_DNs_array+=( "${dn}" )

done

(
    echo "INFO: currently appointed DNs"
    for dn in "${appointed_DNs_array[@]}"
    do
	echo "	\"${dn}\""
    done
) 1>&2

allowed_DNs_ldap_search_result=$(

    # dsidm may return line with empty DNs => remove these empty lines

    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}" | \
	sed -n -e '/^dn: /s/^dn: //p' | \
	sed -e '/^[ \t]*$/d' )
# store result in array
declare -a allowed_DNs_array=()
while IFS= read -r line; do
    # skip eventual empty lines
    if [[ -n "${line}" ]]
    then
	allowed_DNs_array+=( "${line}" )
    fi
done <<< ${allowed_DNs_ldap_search_result}
#
# allow new users who reserved and are not already allowed
#

appointed_minus_allowed_DNs=$(
    
    for dn in "${allowed_DNs_array[@]}" "${allowed_DNs_array[@]}" "${appointed_DNs_array[@]}"
    do
	echo "${dn}"
    done | \
    sort | \
    uniq -u
)
# store result in array
declare -a  new_DNs_array=()
while IFS= read -r line; do
    # skip eventual empty lines
    if [[ -n "${line}" ]]
    then
	new_DNs_array+=( "${line}" )
    fi
done <<< ${appointed_minus_allowed_DNs}



#
# grant access to appointed DNs not already granted
#

for dn in "${new_DNs_array[@]}"
do
    grantServiceBoxAccess "${dn}"
    (
	echo "INFO: granted acces to DN \"${dn}\""
    ) 1>&2
done

#
# revoke all users who did not reserve and are currently allowed
#

allowed_DNs_minus_appointed=$(
    
    for dn in "${appointed_DNs_array[@]}" "${appointed_DNs_array[@]}" "${allowed_DNs_array[@]}"
    do
	echo "${dn}"
    done | \
    sort | \
    uniq -u
)
# store result in array
declare -a  terminated_DNs_array=()
while IFS= read -r line; do
    # skip eventual empty lines
    if [[ -n "${line}" ]]
    then
	terminated_DNs_array+=( "${line}" )
    fi
done <<< ${allowed_DNs_minus_appointed}

for dn in "${terminated_DNs_array[@]}"
do
    revokeServiceBoxAccess "${dn}"
    (
	echo "INFO: revoked acces to DN \"${dn}\""
    ) 1>&2
done

(
    echo "INFO: current members of LDAP group \"${ALLOWING_LDAP_GROUP_NAME}\""
    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}" | sed -e 's/^/\t==>/'
) 1>&2
