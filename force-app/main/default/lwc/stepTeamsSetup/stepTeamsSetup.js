import { LightningElement, api } from 'lwc';
export default class StepTeamsSetup extends LightningElement {
    @api enabled = false; @api complete = false;
    relayProviderChange(event) { this.dispatchEvent(new CustomEvent('providerchange', { detail: event.detail })); }
    relayStatus(event) { this.complete = event.detail.complete; this.dispatchEvent(new CustomEvent('setupstatuschange', { detail: event.detail })); }
    @api validate() { return !this.enabled || this.complete; }
}