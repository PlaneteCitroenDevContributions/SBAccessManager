#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

source "${PROJECT_ROOT_DIR}/dav_config.env"

: ${PYTHON_BIN:="${PROJECT_ROOT_DIR}/.venv/Scripts/python"}

getVCalData ()
{
    ics_url="$1"

    sanitized_url=$(
	echo "${ics_url}" | tr --delete '\r'
	)

    vcal_data=$(
	curl -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8, iso-8859-1;q=0.5' "${ics_url}" | \
	    sed -z 's/\r\n\ //g'
	     )

    echo "${vcal_data}"
}

ics_url_list=$( ${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null )
XX=$( ${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null )

echo "${ics_url_list}"
echo ${ics_url_list}
exit 1

${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" >/tmp/zz.txt

${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2 >& 9

echo "${ics_url_list}"
cat /tmp/zz.txt
cat <& 9
exit 1

for ics_url in $( echo "${ics_url_list}" )
do

    vcal_data=$( getVCalData ${ics_url} )

    echo ${vcal_data}
    echo

done

