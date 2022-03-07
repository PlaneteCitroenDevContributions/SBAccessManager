#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

export LANG='en_US.utf8'

source "${PROJECT_ROOT_DIR}/dav_config.env"

: ${PYTHON_BIN:="${PROJECT_ROOT_DIR}/.venv/bin/python"}

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
	       -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8' "${ics_url}" )
	# put everything on a single line
	sed -z 's/\r\n\ //g' /tmp/response.txt
    )

    echo "${vcal_data}"
}

grantServiceBoxAccess ()
{
    ldap_dn="$1"

    dsidm --pwdfile /etc/pwdfile.txt pcds group add_member ServiceBoxAllowed  "${ldap_dn}"
    
}

revokeServiceBoxAccess ()
{
    ldap_dn="$1"

    dsidm --pwdfile /etc/pwdfile.txt pcds group remove_member ServiceBoxAllowed  "${ldap_dn}"
}


ics_url_list=$(
    ${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null
)

for ics_url in $( echo "${ics_url_list}" )
do

    vcal_data=$( getVCalData ${ics_url} )

    organizer_line=$(
	echo "${vcal_data}" | grep -e '^ORGANIZER;'
		  )

    organizer_data=$(
	echo "${organizer_line}" | sed -e 's/ORGANIZER;//' -e 's/\r$//'
	     )

    displayName=$( echo "${organizer_data}" | sed -e 's/CN=\(.*\):mailto:.*$/\1/' )
    mailto=$( echo "${organizer_data}" | sed -e 's/.*:mailto:\(.*\)$/\1/' )

    echo ${displayName}
    echo ${mailto}

    dn_search_result=$(
	ldapsearch -x -b 'ou=people,dc=planetecitroen,dc=fr' -H ldap://ldap:3389 -z 1 "mail=${mailto}" dn mail
		    )

    if grep '--regexp=^mail:' <<< ${dn_search_result}
    then
	# ldap search result OK
	:
    else
	echo "INTERNAL ERROR: Could not file \"${mailto}\" in ldap" 1>&2
	continue
    fi

    ldap_mail=$( sed -n -e '/^mail: /s/^mail: //p' <<< ${dn_search_result} )
    #
    # for security, we check that the retrieved mail is what we searched fo
    #
    if [[ "${mailto}" != "${ldap_mail}" ]]
    then
	echo "INTERNAL ERROR: Searched for \"${mailto}\" and found \"${ldap_mail}\" in ldap" 1>&2
	continue
    fi
    
    ldap_dn=$( sed -n -e '/^dn: /s/^dn: //p' <<< ${dn_search_result} )

    grantServiceBoxAccess "${ldap_dn}"

    dsidm --pwdfile /etc/pwdfile.txt pcds group members ServiceBoxAllowed
    
    revokeServiceBoxAccess "${ldap_dn}"

    dsidm --pwdfile /etc/pwdfile.txt pcds group members ServiceBoxAllowed
    
done
