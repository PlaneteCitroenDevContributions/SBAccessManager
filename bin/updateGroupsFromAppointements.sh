#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

if [[ -n "${SHELL_DEBUG}" ]]
then
    set -x
    env
fi

: ${LDAP_URL:='ldap://ldap:3389'}

dsidm_cmd_to_evaluate="dsidm --basedn 'dc=planetecitroen,dc=fr' --binddn 'cn=Directory Manager' --pwdfile '/etc/pwdfile.txt' --json '${LDAP_URL}'"
ldapsearch_cmd="ldapsearch -x -b ou=people,dc=planetecitroen,dc=fr -H ldap://ldap:3389"

export LANG='en_US.utf8'

: ${ALLOWING_LDAP_GROUP_NAME:='ServiceBoxAllowed'}

: ${PYTHON_BIN:="${PROJECT_ROOT_DIR}/.venv/bin/python"}

_notify_by_mail ()
{

    email_to_address="$1"
    html_body_file_name="$2"

    # FIXME:
    email_to_address='raphael.bernhard@orange.fr'

    if [[ -r "${html_body_file_name}" ]]
    then
	# file exists
	:
    else
        # Skip action
        return 0
    fi
    
    if [[ -z "${SMTP_HOST}" ]]
    then
        # Skip action
        return 0
    fi

    mail_subject="[PC][ServiceBox] Votre réservation n'a pa pu être honorée"

    : ${RAW_MAIL_FILE:=$( mktemp --dry-run --suffix=_raw_mail4action_notification.txt )}
    : ${SMTP_PORT:=25}

    (
        echo 'Content-Type: text/html; charset="utf-8"'
        echo 'Content-Transfer-Encoding: base64'
        echo "From: staff@planete-citroen.com"
        echo "To: ${email_to_address}"
        echo "Subject: ${mail_subject}"
        echo
        cat "${html_body_file_name}" | base64
    ) > "${RAW_MAIL_FILE}"

    curl --silent --show-error \
        --mail-from 'staff@planete-citroen.com' \
        --mail-rcpt "${email_to_address}" \
        --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
        --upload-file "${RAW_MAIL_FILE}"

    # FIXME:
    #!! rm -f "${RAW_MAIL_FILE}"
}


getVCalData ()
{
    ics_url="$1"

    sanitized_url=$(
	echo "${ics_url}" | tr --delete '\r'
	)

    vcal_data=$(
	test -r /tmp/response && rm /tmp/response.txt
	code=$(
	    curl \
	       --silent --show-error -w '%{http_code}' -o /tmp/response.txt \
	       -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8' "${ics_url}"'?export' )
	# put everything on a single line
	sed -z 's/\r\n\ //g' /tmp/response.txt
    )

    echo "${vcal_data}"
}

grantServiceBoxAccess ()
{
    ldap_dn="$1"

    eval ${dsidm_cmd_to_evaluate} group add_member \'${ALLOWING_LDAP_GROUP_NAME}\'  \'${ldap_dn}\'
    
}

userHasCapabilities ()
{
    ldap_dn="$1"

    var_names_holding_mandatory_ldap_group_names="
	USER_MUST_BE_MEMBER_OF_LDAP_GROUP1
	USER_MUST_BE_MEMBER_OF_LDAP_GROUP2
	USER_MUST_BE_MEMBER_OF_LDAP_GROUP3"

    uid=$( eval ${dsidm_cmd_to_evaluate} user get_dn \'${ldap_dn}\' )
    current_group_dns_for_ldap_dn=$(
	eval ${dsidm_cmd_to_evaluate} user get \'${uid}\' | \
	    jq -r '.attrs.memberof[]'
			      )

    current_group_ids_for_ldap_dn=$(
	for group_dn in ${current_group_dns_for_ldap_dn}
	do
	    eval ${dsidm_cmd_to_evaluate} group get_dn \'${group_dn}\'
	done
	)
	

    for var_name in ${var_names_holding_mandatory_ldap_group_names}
    do
	#test if var is set
	eval "var_val=\"\${${var_name}}\""

	if [[ -n "${var_val}" ]]
	then

	    mandatory_group="${var_val}"

	    if grep --fixed-string "${mandatory_group}" <<< ${current_group_ids_for_ldap_dn}
	    then
		(
		    echo "DEBUG: ${ldap_dn} is member of mandatory group ${mandatory_group}"
		) 1>&2
	    else
		(
		    echo "INFO: ${ldap_dn} is NOT member of mandatory group ${mandatory_group}"
		    email_address_for_ldap_uid=$(
			eval ${dsidm_cmd_to_evaluate} user get \'${uid}\' | \
			    jq -r '.attrs.mail[]' )
		    
		    _notify_by_mail "${email_address_for_ldap_uid}" "${HERE}/etc/mail_body_error_for_${var_name}"
		) 1>&2
		return 1
	    fi

	fi
    done

    return 0
}

revokeServiceBoxAccess ()
{
    ldap_dn="$1"

    eval ${dsidm_cmd_to_evaluate} group remove_member \'${ALLOWING_LDAP_GROUP_NAME}\'  \'${ldap_dn}\'
}


if [[ -z "${TEST_ICS_URL_LIST}" ]]
then
    ics_url_list=$(
	${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null
    )
else
    ics_url_list="${TEST_ICS_URL_LIST}"
fi

#
# search for all users who reserved
#

declare -a appointed_DNs_array=()

for ics_url in $( echo "${ics_url_list}" )
do

    raw_vcal_data=$( getVCalData ${ics_url} )

    vcal_data=$(
	echo "${raw_vcal_data}" | sed -e 's/\r$//'
	     )

    organizer_data=$(
	echo "${vcal_data}" | sed -n -e 's/ORGANIZER;//p'
	     )

    summary_data=$(
	echo "${vcal_data}" | sed -n -e 's/^SUMMARY://p'
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

    eval ${dsidm_cmd_to_evaluate} group members \'${ALLOWING_LDAP_GROUP_NAME}\' | \
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
    if userHasCapabilities "${dn}"
    then
	grantServiceBoxAccess "${dn}"
	(
	    echo "INFO: granted acces to DN \"${dn}\""
	) 1>&2
    else
	(
	    echo "INFO: user with DN \"${dn}\" does not have the required capabilies"
	) 1>&2
    fi
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
    eval ${dsidm_cmd_to_evaluate} group members \'${ALLOWING_LDAP_GROUP_NAME}\' | sed -e 's/^/\t==>/'
) 1>&2
