import os
import sys
import caldav
import datetime
from dotenv import load_dotenv

#
# lInitialize env config file
#
this_file_dirname = os.path.dirname( __file__)
env_path = os.path.join (this_file_dirname, '..', 'dav_config.env')
load_dotenv(dotenv_path=env_path, verbose=True, override=False)


#
# get running environnement
#

caldav_principal_url = os.getenv("CALDAV_PRINCIPAL_URL", 'https://cloud.forumtestplanetecitroen.fr/remote.php/dav')
caldav_username = os.getenv("CALDAV_USERNAME")
caldav_password = os.getenv("CALDAV_PASSWORD")
servicebox_calendar_name = os.getenv("SERVICE_BOX_CALENDAR_NAME", '')



def main ():
    
    client = caldav.DAVClient(url=caldav_principal_url, username=caldav_username, password=caldav_password)
    my_principal = client.principal()

    calendars = my_principal.calendars()
    
    servicebox_calendar = None
    if servicebox_calendar_name != '':
        for c in calendars:
            print ('Found calendar ' + c.name, file=sys.stderr)
            if c.name == servicebox_calendar_name:
                servicebox_calendar = c
                break
    
    if not servicebox_calendar:
        print ('Specific calendar ' + servicebox_calendar_name + ' not found. Using principal', file=sys.stderr)
        servicebox_calendar=calendars[0]
    
    ## Let's search for the newly added event.
    ## (this may fail if the server doesn't support expand)
    print("Here is some icalendar data for the next 60 minutes:")
    start = datetime.datetime.now()
    time_range = datetime.timedelta(minutes=60)
    end = start + time_range
    events_fetched = []
    try:
    
        events_fetched = servicebox_calendar.date_search(start=start, end=end, expand=True) #compfilter=None, 

    except:
        print("Your calendar server does apparently not support expanded search", file=sys.stderr)


    for event in events_fetched:
        # print canonical URL
        print (event.canonical_url)
    
    return


if __name__ == '__main__':
    main ()