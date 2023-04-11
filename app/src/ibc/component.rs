// Many of the IBC message types are enums, where the number of variants differs
// depending on the build configuration, meaning that the fallthrough case gets
// marked as unreachable only when not building in test configuration.
#![allow(unreachable_patterns)]

pub(crate) mod channel;
pub(crate) mod client;
pub(crate) mod connection;
pub(crate) mod state_key;

use crate::ibc::component::client::StateWriteExt as _;
use crate::ibc::ClientCounter;
use crate::Component;
use anyhow::Result;
use async_trait::async_trait;
use ibc::clients::ics07_tendermint::consensus_state::ConsensusState as TendermintConsensusState;
use ibc::core::ics02_client::height::Height;
use penumbra_chain::genesis;
use penumbra_storage::StateWrite;
use tendermint::abci;
use tracing::instrument;

pub struct IBCComponent {}

#[async_trait]
impl Component for IBCComponent {
    #[instrument(name = "ibc", skip(state, _app_state))]
    async fn init_chain<S: StateWrite>(mut state: S, _app_state: &genesis::AppState) {
        // set the initial client count
        state.put_client_counter(ClientCounter(0));
    }

    #[instrument(name = "ibc", skip(state, begin_block))]
    async fn begin_block<S: StateWrite>(mut state: S, begin_block: &abci::request::BeginBlock) {
        // In BeginBlock, we want to save a copy of our consensus state to our
        // own state tree, so that when we get a message from our
        // counterparties, we can verify that they are committing the correct
        // consensus states for us to their state tree.
        let commitment_root: Vec<u8> = begin_block.header.app_hash.clone().into();
        let cs = TendermintConsensusState::new(
            commitment_root.into(),
            begin_block.header.time,
            begin_block.header.next_validators_hash,
        );

        // Currently, we don't use a revision number, because we don't have
        // any further namespacing of blocks than the block height.
        let revision_number = 0;
        let height = Height::new(revision_number, begin_block.header.height.into())
            .expect("block height cannot be zero");

        state.put_penumbra_consensus_state(height, cs);
    }

    #[instrument(name = "ibc", skip(_state, _end_block))]
    async fn end_block<S: StateWrite>(mut _state: S, _end_block: &abci::request::EndBlock) {}

    async fn end_epoch<S: StateWrite>(mut _state: S) -> Result<()> {
        Ok(())
    }
}