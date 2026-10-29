//! Poll interface snapshots on iOS instead of depending on private BSD route ABI.
use n0_error::stack_error;
use tokio::sync::mpsc;
use super::actor::NetworkMessage;
#[stack_error(derive, add_meta)]
pub struct Error;
#[derive(Debug)]
pub(super) struct RouteMonitor { task: tokio::task::JoinHandle<()> }
impl RouteMonitor {
    pub(super) fn new(sender:mpsc::Sender<NetworkMessage>)->Result<Self,Error> {
        let task=tokio::spawn(async move {let mut tick=tokio::time::interval(std::time::Duration::from_secs(5));loop {tick.tick().await;if sender.send(NetworkMessage::Change).await.is_err(){break;}}});
        Ok(Self{task})
    }
}
impl Drop for RouteMonitor {fn drop(&mut self){self.task.abort();}}
