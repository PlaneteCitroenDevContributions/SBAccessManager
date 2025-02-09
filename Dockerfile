# syntax=docker/dockerfile:1
FROM almalinux:9

RUN dnf install -y \
       emacs-nox \
       strace \
       mlocate \
       epel-release \
    && \
    dnf clean all

RUN dnf install -y \
       python3.9 \
    && \
    dnf clean all

RUN python3.9 -m pip install pipenv

RUN dnf module install -y \
    	389-directory-server:stable/minimal \
    && \
    dnf clean all

RUN dnf install -y \
       openldap-clients \
       python3-lib389 \
    && \
    dnf clean all

WORKDIR /code

RUN mkdir .venv
COPY Pipfile .

RUN python3.9 -m pipenv install

COPY bin/updateGroupsFromAppointements.sh  bin/updateGroupsFromAppointements.sh
COPY bin/syncForumAffiliatedWithLdapGroups.sh  bin/syncForumAffiliatedWithLdapGroups.sh
COPY src/getAppointments4Date.py src/getAppointments4Date.py

ENV SHELL_DEBUG=
ENV CALDAV_PRINCIPAL_URL=
ENV CALDAV_USERNAME=
ENV CALDAV_PASSWORD=
ENV SERVICE_BOX_CALENDAR_NAME=
ENV CLOUD_AFFILIATED_LDAP_GROUP_NAME=
ENV INVISION_API_KEY=
ENV INVISION_GROUP_ID1=
ENV INVISION_GROUP_ID2=
ENV INVISION_GROUP_ID3=


#ENTRYPOINT [ "/usr/sbin/dsidm", "-y", "/etc/pwdfile.txt" ]
#ENTRYPOINT [ "/bin/bash" ]
CMD [ "/code/bin/updateGroupsFromAppointements.sh" ]
