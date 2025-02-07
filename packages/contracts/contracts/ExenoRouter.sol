// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";
import "./lib/LibAsset.sol";
import "./interfaces/ITransactionManager.sol";

interface ITransactionManagerExt is ITransactionManager {
  function routerBalances(address, address) external view returns(uint256);
}

contract ChildAsset is Ownable, ERC1363 {

  uint256 public immutable lockedSupply;

  constructor(
    string memory _name,
    string memory _symbol,
    uint256 _lockedSupply
  )
    ERC20(_name, _symbol)
  {
    _mint(_msgSender(), _lockedSupply);
    lockedSupply = _lockedSupply;
  }

  function mint(uint256 amount)
    external onlyOwner
  {
    _mint(_msgSender(), amount);
  }

  function burn(uint256 amount)
    external onlyOwner
  {
    _burn(_msgSender(), amount);
  }

  function unlockedSupply()
    external view returns(uint256)
  {
    return totalSupply() - lockedSupply;
  }
}

contract ExenoRouter is Ownable {

  address public immutable routerFactory;

  ITransactionManagerExt public transactionManager;

  ChildAsset public childAsset;

  address public recipient;

  address public routerSigner;

  uint256 private chainId;

  struct SignedPrepareData {
    ITransactionManager.PrepareArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedFulfillData {
    ITransactionManager.FulfillArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedCancelData {
    ITransactionManager.CancelArgs args;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  struct SignedRemoveLiquidityData {
    uint256 amount;
    address assetId;
    address routerRelayerFeeAsset;
    uint256 routerRelayerFee;
    uint256 chainId; // For domain separation
  }

  event RelayerFeeAdded(address assetId, uint256 amount, address caller);
  event RelayerFeeRemoved(address assetId, uint256 amount, address caller);
  event RemoveLiquidity(
    uint256 amount, 
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee, 
    address caller
  );
  event Prepare(
    ITransactionManager.InvariantTransactionData invariantData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );
  event Fulfill(
    ITransactionManager.TransactionData txData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );
  event Cancel(
    ITransactionManager.TransactionData txData,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    address caller
  );

  constructor(address _routerFactory)
  {
    routerFactory = _routerFactory;
  }

  // Prevents from calling methods other than routerFactory contract
  modifier onlyViaFactory() {
    require(msg.sender == routerFactory, "ONLY_VIA_FACTORY");
    _;
  }

  function init(
    address _transactionManager,
    uint256 _chainId,
    address _routerSigner,
    address _recipient,
    address _owner
  )
    external onlyViaFactory
  {
    transactionManager = ITransactionManagerExt(_transactionManager);
    chainId = _chainId;
    routerSigner = _routerSigner;
    recipient = _recipient;
    transferOwnership(_owner);
  }

  function initChildAsset(
    string memory name,
    string memory symbol,
    uint256 lockedSupply
  )
    external onlyOwner
  {
    require(address(childAsset) == address(0x0), "CHILD_ASSET_ALREADY_INITIALIZED");
    childAsset = new ChildAsset(name, symbol, lockedSupply);
    childAsset.approve(address(transactionManager), lockedSupply);
    transactionManager.addLiquidity(lockedSupply, address(childAsset));
  }

  function setRecipient(address _recipient)
    external onlyOwner
  {
    recipient = _recipient;
  }

  function setSigner(address _routerSigner)
    external onlyOwner
  {
    routerSigner = _routerSigner;
  }

  function addRelayerFee(uint256 amount, address assetId)
    external payable
  {
    // Sanity check: nonzero amounts
    require(amount > 0, "#RC_ARF:002");

    // Transfer funds to contract
    // Validate correct amounts are transferred
    if (LibAsset.isNativeAsset(assetId)) {
      require(msg.value == amount, "#RC_ARF:005");
    } else {
      require(msg.value == 0, "#RC_ARF:006");
      LibAsset.transferFromERC20(assetId, msg.sender, address(this), amount);
    }

    // Emit event
    emit RelayerFeeAdded(assetId, amount, msg.sender);
  }

  function getLiquidityForAsset(address assetId)
    external view returns(uint256)
  {
    return transactionManager.routerBalances(address(this), assetId);
  }

  function getLiquidityForChildAsset()
    public view returns(uint256)
  {
    return transactionManager.routerBalances(address(this), address(childAsset));
  }

  function getCashBalance()
    external view returns(uint256)
  {
    return address(this).balance;
  }

  function withdrawCashBalance()
    external onlyOwner
  {
    LibAsset.transferNativeAsset(payable(recipient), address(this).balance);
  }

  function removeRelayerFee(uint256 amount, address assetId)
    external onlyOwner
  {
    // Sanity check: nonzero amounts
    require(amount > 0, "#RC_RRF:002");

    // Transfer funds from contract
    LibAsset.transferAsset(assetId, payable(recipient), amount);

    // Emit event
    emit RelayerFeeRemoved(assetId, amount, msg.sender);
  }

  function removeLiquidity(
    uint256 amount,
    address assetId,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external
  {
    if (msg.sender != routerSigner) {
      SignedRemoveLiquidityData memory payload = SignedRemoveLiquidityData({
        amount: amount,
        assetId: assetId,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_RL:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    if (assetId == address(childAsset)) {
      require(getLiquidityForChildAsset() >= childAsset.lockedSupply() + amount,
        "CHILD_ASSET_LIQUIDITY_CANNOT_GET_BELOW_LOCKED_SUPPLY");
    }

    emit RemoveLiquidity(amount, assetId, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    return transactionManager.removeLiquidity(amount, assetId, payable(recipient));
  }

  function prepare(
    ITransactionManager.PrepareArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external payable returns(ITransactionManager.TransactionData memory)
  {
    if (msg.sender != routerSigner) {
      SignedPrepareData memory payload = SignedPrepareData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_P:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit Prepare(args.invariantData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.prepare(args);

    if (args.invariantData.receivingAssetId == address(childAsset)) {
      childAsset.mint(args.amount);
      childAsset.approve(address(transactionManager), args.amount);
      transactionManager.addLiquidity(args.amount, address(childAsset));
    }
    return txData;
  }

  function fulfill(
    ITransactionManager.FulfillArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external returns(ITransactionManager.TransactionData memory)
  {
    if (msg.sender != routerSigner) {
      SignedFulfillData memory payload = SignedFulfillData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_F:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }

    emit Fulfill(args.txData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.fulfill(args);

    if (args.txData.sendingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
    }
    return txData;
  }

  function cancel(
    ITransactionManager.CancelArgs calldata args,
    address routerRelayerFeeAsset,
    uint256 routerRelayerFee,
    bytes calldata signature
  )
    external returns(ITransactionManager.TransactionData memory)
  {
    if (msg.sender != routerSigner) {
      SignedCancelData memory payload = SignedCancelData({
        args: args,
        routerRelayerFeeAsset: routerRelayerFeeAsset,
        routerRelayerFee: routerRelayerFee,
        chainId: chainId
      });

      address recovered = recoverSignature(abi.encode(payload), signature);
      require(recovered == routerSigner, "#RC_C:040");

      // Send the relayer the fee
      if (routerRelayerFee > 0) {
        LibAsset.transferAsset(routerRelayerFeeAsset, payable(msg.sender), routerRelayerFee);
      }
    }
    emit Cancel(args.txData, routerRelayerFeeAsset, routerRelayerFee, msg.sender);
    ITransactionManager.TransactionData memory txData = transactionManager.cancel(args);

    if (args.txData.receivingAssetId == address(childAsset)) {
      transactionManager.removeLiquidity(args.txData.amount, address(childAsset), payable(this));
      childAsset.burn(args.txData.amount);
    }
    return txData;
  }

  /**
   * @notice Holds the logic to recover the routerSigner from an encoded payload.
   *         Will hash and convert to an eth signed message.
   * @param encodedPayload The payload that was signed
   * @param signature The signature you are recovering the routerSigner from
   */
  function recoverSignature(bytes memory encodedPayload, bytes calldata signature)
    internal pure returns(address)
  {
    // Recover
    return ECDSA.recover(ECDSA.toEthSignedMessageHash(keccak256(encodedPayload)), signature);
  }

  receive() external payable {}
}
