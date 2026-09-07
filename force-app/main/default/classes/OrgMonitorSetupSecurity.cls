/** Central authorization boundary for privileged Org Monitor setup operations. */
public with sharing class OrgMonitorSetupSecurity {
    private static final String MANAGE_SETUP_PERMISSION = 'Org_Monitor_Manage_Setup';
    @TestVisible private static Boolean testPermissionGranted = false;

    public static void requireManageSetup() {
        Boolean granted = FeatureManagement.checkPermission(MANAGE_SETUP_PERMISSION);
        if (Test.isRunningTest()) granted = testPermissionGranted;
        if (!granted) throw new AuraHandledException('ORG_MONITOR_SETUP_ACCESS_REQUIRED');
    }
}