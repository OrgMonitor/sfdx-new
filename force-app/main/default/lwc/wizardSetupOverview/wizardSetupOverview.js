import { LightningElement, api } from 'lwc';

export default class WizardSetupOverview extends LightningElement {
    @api steps = [];
    @api currentStepIndex = 0;

    get overviewItems() {
        return this.steps.map(step => ({
            label: step.label,
            configStatus: step.configStatus,
            statusClass: step.configStatus === 'Configured'
                ? 'wso-status wso-status--configured'
                : 'wso-status wso-status--pending',
        }));
    }

    get hasMore() {
        return false;
    }
}