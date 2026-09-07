import { LightningElement, api } from 'lwc';

export default class StepReview extends LightningElement {
    @api deploymentUsers  = [];
    @api enableApproval   = false;
    @api approvalUsers    = [];
    @api initialRunWindow = '';
    @api slackEnabled = false;
    @api microsoftEnabled = false;
    @api slackSetupComplete = false;
    @api microsoftSetupComplete = false;
    @api slackIdentity = '';
    @api microsoftIdentity = '';

    get slackStatus() { return !this.slackEnabled ? 'Disabled' : this.slackSetupComplete ? `Connected and tested${this.slackIdentity ? ` — ${this.slackIdentity}` : ''}` : 'Enabled — test message required'; }
    get microsoftStatus() { return !this.microsoftEnabled ? 'Disabled' : this.microsoftSetupComplete ? `Connected and tested${this.microsoftIdentity ? ` — ${this.microsoftIdentity}` : ''}` : 'Enabled — test message required'; }

    get hasDeploymentUsers() {
        return this.deploymentUsers && this.deploymentUsers.length > 0;
    }

    get hasApprovalUsers() {
        return this.approvalUsers && this.approvalUsers.length > 0;
    }

    get approvalLabel() {
        return this.enableApproval ? 'Enabled' : 'Disabled';
    }

    get approvalBadgeClass() {
        return this.enableApproval ? 'sr-badge sr-badge--success' : 'sr-badge sr-badge--neutral';
    }
}