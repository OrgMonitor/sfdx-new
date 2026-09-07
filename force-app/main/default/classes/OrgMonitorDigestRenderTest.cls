@IsTest
private class OrgMonitorDigestRenderTest {
    private static OrgMonitorChangeDigestModel digest(Integer critical, Integer high,
            Integer compliant) {
        OrgMonitorChangeDigestModel value = new OrgMonitorChangeDigestModel();
        value.effectiveActorId = UserInfo.getUserId(); value.effectiveActorName = 'Admin <＠channel>';
        value.periodStart = Datetime.newInstanceGMT(2026, 9, 4, 17, 25, 0);
        value.periodEnd = Datetime.newInstanceGMT(2026, 9, 4, 17, 30, 0);
        value.orgTimeZoneSidKey = 'Australia/Sydney'; value.correlationId = 'OM-TEST';
        value.criticalNonCompliantCount = critical; value.highNonCompliantCount = high;
        value.nonCompliantCount = critical + high; value.compliantCount = compliant;
        value.totalCount = value.nonCompliantCount + compliant;
        return value;
    }
    @IsTest static void highOnlyDigestHasCountsReasonsAndNoDetails() {
        OrgMonitorChangeDigestModel value = digest(0, 4, 0);
        OrgMonitorChangeDigestModel.ReasonSummary reason = new OrgMonitorChangeDigestModel.ReasonSummary();
        reason.count = 4; reason.reasonCode = 'USER_NOT_NOMINATED';
        reason.windowName = 'CHW-00136'; reason.conciseText =
            'Admin was not nominated for deployment window CHW-00136.';
        value.nonComplianceReasons.add(reason);
        OrgMonitorChangeDigestRenderer.RenderedDigest rendered =
            new OrgMonitorChangeDigestRenderer().render(value);
        System.assertEquals('⚠️ Org Monitor — Changes require review', rendered.title);
        System.assert(rendered.slackBlocksJson.contains('High 4'));
        System.assert(rendered.teamsHtml.contains('High 4'));
        System.assert(!rendered.slackBlocksJson.contains('CREATE_OR_ADD'));
        System.assert(!rendered.teamsHtml.contains('CRITICAL NON-COMPLIANT CHANGES'));
        System.assert(!rendered.teamsHtml.contains('Apex class'));
        System.assert(rendered.teamsHtml.contains('&lt;＠channel&gt;'));
        System.assertEquals(0, value.criticalChanges.size());
    }
    @IsTest static void onlyCriticalNonCompliantIsListedAndHumanised() {
        OrgMonitorChangeDigestModel value = digest(1, 1, 1);
        OrgMonitorChangeDigestModel.CriticalChangeItem item =
            new OrgMonitorChangeDigestModel.CriticalChangeItem();
        item.readableOperation = OrgMonitorChangeDigestBuilder.operation('CREATE_OR_ADD');
        item.metadataType = OrgMonitorChangeDigestBuilder.metadataLabel('PermissionSet');
        item.componentName = 'Service <Admin>'; item.changeTime = value.periodEnd;
        item.conciseReason = 'No deployment window covered this change.';
        item.delegatedAccess = true; item.effectiveActorName = 'Jane Admin';
        item.actingAsUserName = 'Release User'; value.criticalChanges.add(item);
        OrgMonitorChangeDigestRenderer.RenderedDigest rendered =
            new OrgMonitorChangeDigestRenderer().render(value);
        System.assertEquals('🚨 Org Monitor — Critical changes require review', rendered.title);
        System.assert(rendered.teamsHtml.contains('Created Permission set'));
        System.assert(!rendered.teamsHtml.contains('CREATE_OR_ADD'));
        System.assert(rendered.teamsHtml.contains('while logged in as Release User'));
        System.assert(rendered.teamsHtml.contains('Service &lt;Admin&gt;'));
    }
    @IsTest static void orgTimezoneHandlesStandardDaylightAndMidnight() {
        OrgMonitorDateTimeFormatter formatter = new OrgMonitorDateTimeFormatter('Australia/Sydney');
        System.assert(formatter.formatDateTime(Datetime.newInstanceGMT(2026, 6, 5, 0, 0, 0)).contains('AEST'));
        System.assert(formatter.formatDateTime(Datetime.newInstanceGMT(2026, 12, 5, 0, 0, 0)).contains('AEDT'));
        String transition = formatter.formatPeriod(
            Datetime.newInstanceGMT(2026, 10, 3, 15, 55, 0),
            Datetime.newInstanceGMT(2026, 10, 3, 16, 5, 0));
        System.assert(transition.contains('AEST') && transition.contains('AEDT'));
        String midnight = formatter.formatPeriod(
            Datetime.newInstanceGMT(2026, 9, 5, 13, 55, 0),
            Datetime.newInstanceGMT(2026, 9, 5, 14, 5, 0));
        System.assert(midnight.contains('5 Sep') && midnight.contains('6 Sep'));
    }
    @IsTest static void nonCompliantLoginAsUsesAdministrativeSecurityItem() {
        OrgMonitorChangeDigestModel value = digest(1, 0, 0);
        OrgMonitorChangeDigestModel.CriticalChangeItem item =
            new OrgMonitorChangeDigestModel.CriticalChangeItem();
        item.readableOperation = 'Logged in as'; item.metadataType = 'Login-As Access';
        item.componentName = 'Rohit G'; item.changeTime = value.periodEnd;
        item.conciseReason = 'Jitendra was not nominated for deployment window CHW-00136.';
        item.delegatedAccess = true; item.effectiveActorName = 'Jitendra Kawale';
        item.actingAsUserName = 'Rohit G'; value.criticalChanges.add(item);
        OrgMonitorChangeDigestRenderer.RenderedDigest rendered =
            new OrgMonitorChangeDigestRenderer().render(value);
        System.assert(rendered.slackBlocksJson.contains('Administrative Login-As Access'));
        System.assert(rendered.slackBlocksJson.contains('Jitendra Kawale logged in as Rohit G'));
        System.assert(rendered.teamsHtml.contains('Administrative Login-As Access'));
        System.assert(rendered.teamsHtml.contains('Jitendra Kawale logged in as Rohit G'));
    }
    @IsTest static void largeCriticalDigestSplitsAtItemBoundaries() {
        OrgMonitorChangeDigestModel value = digest(61, 0, 0);
        for (Integer index = 1; index <= 61; index++) {
            OrgMonitorChangeDigestModel.CriticalChangeItem item =
                new OrgMonitorChangeDigestModel.CriticalChangeItem();
            item.readableOperation = 'Changed'; item.metadataType = 'Apex class';
            item.componentName = 'Component ' + index; item.changeTime = value.periodEnd;
            item.conciseReason = 'Outside a deployment window.';
            value.criticalChanges.add(item);
        }
        List<OrgMonitorChangeDigestModel> parts =
            OrgMonitorChangeDigestService.splitCriticalChanges(value);
        System.assertEquals(3, parts.size());
        System.assertEquals(30, parts[0].criticalChanges.size());
        System.assertEquals(30, parts[1].criticalChanges.size());
        System.assertEquals(1, parts[2].criticalChanges.size());
        OrgMonitorChangeDigestRenderer renderer = new OrgMonitorChangeDigestRenderer();
        OrgMonitorChangeDigestRenderer.RenderedDigest first = renderer.render(parts[0], 1, 3);
        OrgMonitorChangeDigestRenderer.RenderedDigest last = renderer.render(parts[2], 3, 3);
        System.assert(first.teamsHtml.contains('Part 1 of 3'));
        System.assert(first.teamsHtml.contains('61 Salesforce changes detected'));
        System.assert(!last.teamsHtml.contains('61 Salesforce changes detected'));
        System.assert(last.teamsHtml.contains('Part 3 of 3'));
    }
}