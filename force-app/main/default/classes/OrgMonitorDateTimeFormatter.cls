/** Formats business-facing dates exclusively in the Salesforce organisation timezone. */
public inherited sharing class OrgMonitorDateTimeFormatter {
    public String timeZoneSidKey { get; private set; }
    public OrgMonitorDateTimeFormatter(String timeZoneSidKey) {
        if (String.isBlank(timeZoneSidKey)) throw new FormatterException('Organisation timezone is required.');
        this.timeZoneSidKey = timeZoneSidKey;
        try { TimeZone.getTimeZone(timeZoneSidKey); }
        catch (Exception error) { throw new FormatterException('Organisation timezone is invalid.'); }
    }
    public String formatDateTime(Datetime value) {
        return value == null ? null : value.format('d MMM yyyy, h:mm a z', timeZoneSidKey);
    }
    public String formatTime(Datetime value) {
        return value == null ? null : value.format('h:mm a z', timeZoneSidKey);
    }
    public Date toOrgLocalDate(Datetime value) {
        return value == null ? null : Date.valueOf(value.format('yyyy-MM-dd', timeZoneSidKey));
    }
    public String formatPeriod(Datetime startValue, Datetime endValue) {
        if (startValue == null || endValue == null) return null;
        String startDate = startValue.format('d MMM yyyy', timeZoneSidKey);
        String endDate = endValue.format('d MMM yyyy', timeZoneSidKey);
        String startZone = startValue.format('z', timeZoneSidKey);
        String endZone = endValue.format('z', timeZoneSidKey);
        if (startDate == endDate && startZone == endZone) {
            return startDate + ', ' + startValue.format('h:mm', timeZoneSidKey) + '–'
                + endValue.format('h:mm a z', timeZoneSidKey);
        }
        return formatDateTime(startValue) + '–' + formatDateTime(endValue);
    }
    public class FormatterException extends Exception { }
}