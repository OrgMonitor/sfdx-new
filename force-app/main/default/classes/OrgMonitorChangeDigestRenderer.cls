/** Produces provider-native output from one already-calculated digest model. */
public inherited sharing class OrgMonitorChangeDigestRenderer {
    public class RenderedDigest {
        public String title, slackFallbackText, slackBlocksJson, teamsHtml;
    }
    public RenderedDigest render(OrgMonitorChangeDigestModel digest) {
        return render(digest, 1, 1);
    }
    public RenderedDigest render(OrgMonitorChangeDigestModel digest, Integer partNumber, Integer partCount) {
        RenderedDigest result = new RenderedDigest();
        result.title = title(digest);
        result.slackFallbackText = fallback(digest)
            + (partCount > 1 ? ' Part ' + partNumber + ' of ' + partCount + '.' : '');
        result.slackBlocksJson = JSON.serialize(slackBlocks(digest, result.title, partNumber, partCount));
        result.teamsHtml = teams(digest, result.title, partNumber, partCount);
        return result;
    }
    private String title(OrgMonitorChangeDigestModel digest) {
        if (digest.criticalNonCompliantCount > 0) return '🚨 Org Monitor — Critical changes require review';
        if (digest.nonCompliantCount > 0) return '⚠️ Org Monitor — Changes require review';
        return '✅ Org Monitor — Compliant changes detected';
    }
    private String fallback(OrgMonitorChangeDigestModel digest) {
        String changes = digest.totalCount + ' Salesforce change' + (digest.totalCount == 1 ? '' : 's');
        if (digest.criticalNonCompliantCount > 0) return 'Org Monitor detected ' + changes + ' by '
            + plain(digest.effectiveActorName) + '. ' + digest.criticalNonCompliantCount
            + ' critical non-compliant change' + (digest.criticalNonCompliantCount == 1 ? '' : 's')
            + ' require review.';
        if (digest.nonCompliantCount > 0) return 'Org Monitor detected ' + changes + ' by '
            + plain(digest.effectiveActorName) + '. ' + digest.nonCompliantCount
            + ' change' + (digest.nonCompliantCount == 1 ? '' : 's')
            + ' require review; none is Critical.';
        return 'Org Monitor detected ' + changes + ' by ' + plain(digest.effectiveActorName)
            + '. All detected changes are compliant.';
    }
    private List<Object> slackBlocks(OrgMonitorChangeDigestModel digest, String digestTitle,
            Integer partNumber, Integer partCount) {
        OrgMonitorDateTimeFormatter formatter = new OrgMonitorDateTimeFormatter(digest.orgTimeZoneSidKey);
        List<Object> blocks = new List<Object>();
        blocks.add(new Map<String, Object>{ 'type' => 'header', 'text' => new Map<String, Object>{
            'type' => 'plain_text', 'text' => digestTitle, 'emoji' => true } });
        blocks.add(new Map<String, Object>{ 'type' => 'context', 'elements' => new List<Object>{
            new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '👤 *' + slack(digest.effectiveActorName)
                + '*  |  🕒 ' + slack(formatter.formatPeriod(digest.periodStart, digest.periodEnd))
                + partLabel(partNumber, partCount) } } });
        if (partNumber == 1) {
            blocks.add(new Map<String, Object>{ 'type' => 'section', 'fields' => new List<Object>{
                slackField('Total detected', String.valueOf(digest.totalCount)),
                slackField('Non-compliant', '⚠️ ' + digest.nonCompliantCount),
                slackField('Compliant', '✅ ' + digest.compliantCount),
                slackField('Critical non-compliant', '🚨 ' + digest.criticalNonCompliantCount) } });
            String breakdown = severityBreakdown(digest);
            if (String.isNotBlank(breakdown)) blocks.add(slackSection('*Non-compliant severity*\n' + slack(breakdown)));
            addSlackReasons(blocks, digest);
        }
        if (!digest.criticalChanges.isEmpty()) {
            blocks.add(slackSection('*🚨 CRITICAL NON-COMPLIANT CHANGES*'));
            Integer itemNumber = 0;
            for (OrgMonitorChangeDigestModel.CriticalChangeItem item : digest.criticalChanges) {
                itemNumber++;
                Boolean loginAs = item.metadataType == 'Login-As Access';
                String text = loginAs
                    ? itemNumber + '. *🚨 Administrative Login-As Access*'
                    : itemNumber + '. *' + slack(item.readableOperation + ' ' + item.metadataType)
                        + (String.isBlank(item.componentName) ? '' : ' — ' + slack(item.componentName)) + '*';
                if (loginAs && String.isNotBlank(item.actingAsUserName)) text += '\n'
                    + slack(item.effectiveActorName) + ' logged in as ' + slack(item.actingAsUserName);
                else if (item.delegatedAccess == true && String.isNotBlank(item.actingAsUserName)) text += '\nPerformed by '
                    + slack(item.effectiveActorName) + ' while logged in as ' + slack(item.actingAsUserName);
                text += '\n🕒 ' + slack(formatter.formatDateTime(item.changeTime))
                    + '\n*Why flagged:* ' + slack(item.conciseReason);
                blocks.add(slackSection(text));
            }
        }
        if (partNumber == partCount && trustedUrl(digest.reviewUrl)) blocks.add(new Map<String, Object>{ 'type' => 'actions',
            'elements' => new List<Object>{ new Map<String, Object>{ 'type' => 'button',
                'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => 'Review in Org Monitor' },
                'url' => digest.reviewUrl, 'action_id' => 'org_monitor_review' } } });
        return blocks;
    }
    private String teams(OrgMonitorChangeDigestModel digest, String digestTitle,
            Integer partNumber, Integer partCount) {
        OrgMonitorDateTimeFormatter formatter = new OrgMonitorDateTimeFormatter(digest.orgTimeZoneSidKey);
        String html = '<b>' + html(digestTitle) + '</b><br><br>👤 <b>User:</b> '
            + html(digest.effectiveActorName) + '<br>🕒 <b>Period:</b> '
            + html(formatter.formatPeriod(digest.periodStart, digest.periodEnd))
            + (partCount > 1 ? '<br><b>Part ' + partNumber + ' of ' + partCount + '</b>' : '');
        if (partNumber == 1) {
            html += '<br><br><b>' + digest.totalCount + ' Salesforce change'
                + (digest.totalCount == 1 ? '' : 's') + ' detected</b><br><br>⚠️ <b>Non-compliant:</b> '
                + digest.nonCompliantCount + '<br>✅ <b>Compliant:</b> ' + digest.compliantCount
                + '<br>🚨 <b>Critical non-compliant:</b> ' + digest.criticalNonCompliantCount;
            String breakdown = severityBreakdown(digest);
            if (String.isNotBlank(breakdown)) html += '<br><b>Non-compliant severity:</b> ' + html(breakdown);
            html += teamsReasons(digest);
        }
        if (!digest.criticalChanges.isEmpty()) {
            html += '<br><br><b>🚨 CRITICAL NON-COMPLIANT CHANGES</b>';
            Integer itemNumber = 0;
            for (OrgMonitorChangeDigestModel.CriticalChangeItem item : digest.criticalChanges) {
                itemNumber++;
                Boolean loginAs = item.metadataType == 'Login-As Access';
                html += loginAs
                    ? '<br><br>' + itemNumber + '. <b>🚨 Administrative Login-As Access</b>'
                    : '<br><br>' + itemNumber + '. <b>' + html(item.readableOperation + ' ' + item.metadataType
                        + (String.isBlank(item.componentName) ? '' : ' — ' + item.componentName)) + '</b>';
                if (loginAs && String.isNotBlank(item.actingAsUserName)) html += '<br>'
                    + html(item.effectiveActorName) + ' logged in as ' + html(item.actingAsUserName);
                else if (item.delegatedAccess == true && String.isNotBlank(item.actingAsUserName)) html += '<br>Performed by '
                    + html(item.effectiveActorName) + ' while logged in as ' + html(item.actingAsUserName);
                html += '<br>🕒 ' + html(formatter.formatDateTime(item.changeTime))
                    + '<br><b>Why flagged:</b> ' + html(item.conciseReason);
            }
        }
        if (partNumber == partCount && trustedUrl(digest.reviewUrl)) html += '<br><br>🔎 <a href="' + html(digest.reviewUrl)
            + '">Review changes in Org Monitor</a>';
        return html;
    }
    private void addSlackReasons(List<Object> blocks, OrgMonitorChangeDigestModel digest) {
        if (digest.nonComplianceReasons.isEmpty()) return;
        if (digest.nonComplianceReasons.size() == 1) {
            blocks.add(slackSection('*Primary issue*\n' + slack(digest.nonComplianceReasons[0].conciseText)));
            return;
        }
        String value = '*Why changes require review*'; Integer shown = Math.min(3, digest.nonComplianceReasons.size());
        Integer represented = 0;
        for (Integer index = 0; index < shown; index++) { OrgMonitorChangeDigestModel.ReasonSummary reason = digest.nonComplianceReasons[index];
            value += '\n• ' + reason.count + ' — ' + slack(reason.conciseText); represented += reason.count; }
        if (digest.nonCompliantCount > represented) value += '\n• ' + (digest.nonCompliantCount - represented)
            + ' additional changes have other compliance reasons';
        blocks.add(slackSection(value));
    }
    private String teamsReasons(OrgMonitorChangeDigestModel digest) {
        if (digest.nonComplianceReasons.isEmpty()) return '';
        if (digest.nonComplianceReasons.size() == 1) return '<br><br><b>Primary issue</b><br>'
            + html(digest.nonComplianceReasons[0].conciseText);
        String value = '<br><br><b>Why changes require review</b>'; Integer shown = Math.min(3, digest.nonComplianceReasons.size());
        Integer represented = 0;
        for (Integer index = 0; index < shown; index++) { OrgMonitorChangeDigestModel.ReasonSummary reason = digest.nonComplianceReasons[index];
            value += '<br>• ' + reason.count + ' — ' + html(reason.conciseText); represented += reason.count; }
        if (digest.nonCompliantCount > represented) value += '<br>• ' + (digest.nonCompliantCount - represented)
            + ' additional changes have other compliance reasons';
        return value;
    }
    private String severityBreakdown(OrgMonitorChangeDigestModel d) {
        List<String> values = new List<String>();
        if (d.criticalNonCompliantCount > 0) values.add('Critical ' + d.criticalNonCompliantCount);
        if (d.highNonCompliantCount > 0) values.add('High ' + d.highNonCompliantCount);
        if (d.mediumNonCompliantCount > 0) values.add('Medium ' + d.mediumNonCompliantCount);
        if (d.lowNonCompliantCount > 0) values.add('Low ' + d.lowNonCompliantCount);
        if (d.otherNonCompliantCount > 0) values.add('Other ' + d.otherNonCompliantCount);
        return String.join(values, ', ');
    }
    private String partLabel(Integer partNumber, Integer partCount) {
        return partCount > 1 ? '  |  *Part ' + partNumber + ' of ' + partCount + '*' : '';
    }
    private Map<String, Object> slackField(String label, String value) { return new Map<String, Object>{
        'type' => 'mrkdwn', 'text' => '*' + label + '*\n' + value }; }
    private Map<String, Object> slackSection(String value) { return new Map<String, Object>{
        'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => value } }; }
    private Boolean trustedUrl(String value) { return String.isNotBlank(value)
        && value.startsWith(URL.getOrgDomainUrl().toExternalForm() + '/'); }
    private String slack(String value) { return plain(value).replace('&', '&amp;').replace('<', '&lt;')
        .replace('>', '&gt;').replace('@', '＠'); }
    private String html(String value) { return plain(value).replace('&', '&amp;').replace('<', '&lt;')
        .replace('>', '&gt;').replace('"', '&quot;').replace('\'', '&#39;'); }
    private String plain(String value) { return String.isBlank(value) ? '(unavailable)'
        : value.replaceAll('[\\r\\n\\t]+', ' ').trim(); }
}