// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;
pragma experimental ABIEncoderV2;

import "../UsingWitnet.sol";
import "../interfaces/IWitnetRNG.sol";
import "../requests/WitnetRequestRandomness.sol";

/// @title WitnetRNG: A trustless random number generator and registry, based on the Witnet oracle. 
/// @author The Witnet Foundation.
contract WitnetRNG
    is
        IWitnetRNG,
        UsingWitnet,
        Clonable
{
    WitnetRequestRandomness public witnetRandomnessRequest;
    uint256 public override latestRandomizeBlock;

    mapping (uint256 => RandomizeData) internal __randomize_;
    struct RandomizeData {
        address from;
        uint256 prevBlock;
        uint256 nextBlock;
        uint256 witnetQueryId;
    }

    /// Include an address to specify the immutable WitnetRequestBoard entrypoint address.
    /// @param _wrb The WitnetRequestBoard immutable entrypoint address.
    constructor(WitnetRequestBoard _wrb)
        UsingWitnet(_wrb)
    {
        witnetRandomnessRequest = new WitnetRequestRandomness();
        witnetRandomnessRequest.transferOwnership(msg.sender);
    }

    /// Returns amount of weis required to be paid as a fee when requesting randomness with a 
    /// tx gas price as the one given.
    function estimateRandomizeFee(uint256 _gasPrice)
        public view
        virtual override
        returns (uint256)
    {
        return _witnetEstimateReward(_gasPrice);
    }

    /// Gets data of the randomness request that got successfully posted to the WRB within given block.
    /// @dev Returns zero values if no randomness request was actually posted within given block.
    /// @param _block Block number whose randomness request is beign queried.
    /// @return _from Address from which the latest randomness request was posted.
    /// @return _id Unique request identifier as provided by the WRB.
    /// @return _fee Request's total paid fee.
    /// @return _prevBlock Block number in which a randomness request got posted just before this one. 0 if none.
    /// @return _nextBlock Block number in which a randomness request got posted just after this one, 0 if none.
    function getRandomizeData(uint256 _block)
        external view
        override
        returns (
            address _from,
            uint256 _id,
            uint256 _fee,
            uint256 _prevBlock,
            uint256 _nextBlock
        )
    {
        RandomizeData storage _data = __randomize_[_block];
        _id = _data.witnetQueryId;
        _fee = witnet.readRequestReward(_id);
        _from = _data.from;
        _prevBlock = _data.prevBlock;
        _nextBlock = _data.nextBlock;
    }

    /// Gets randomness generated upon resolution to the request that was posted within given block,
    /// if any, or to the _first_ request posted after that block, otherwise.
    /// @dev Fails if:
    /// @dev   i.   no `randomize()` was ever called in either the given block, or afterwards.
    /// @dev   ii.  a request posted in/after given block exists, but no result has yet been provided.
    /// @dev   iii. the implicit request could not be solved by the Witnet oracle, for whatever reason.
    /// @param _block Block number from which the search will start.
    function getRandomnessAfter(uint256 _block)
        public view
        virtual override
        returns (bytes32)
    {
        if (__randomize_[_block].from == address(0)) {
            _block = getRandomnessNextBlock(_block);
        }
        require(isRandomized(_block), "WitnetRNG: not randomized");
        Witnet.Result memory _witnetResult = _witnetReadResult(__randomize_[_block].witnetQueryId);
        require(witnet.isOk(_witnetResult), "WitnetRNG: randomize failed");
        return witnet.asBytes32(_witnetResult);
    }

    /// Gets next block in which a new randomness request was posted after the given one. 
    /// @param _block Block number from which the search will start.
    /// @return First block found after the given one, or `0` otherwise.
    function getRandomnessNextBlock(uint256 _block)
        public view
        virtual override
        returns (uint256)
    {
        return ((__randomize_[_block].from != address(0))
            ? __randomize_[_block].nextBlock
            // start search from the latest block
            : _searchNextBlock(_block, latestRandomizeBlock)
        );
    }

    /// Gets previous block in which a randomness request was posted before the given one.
    /// @param _block Block number from which the search will start. Cannot be zero.
    /// @return First block found before the given one, or `0` otherwise.
    function getRandomnessPrevBlock(uint256 _block)
        public view
        virtual override
        returns (uint256)
    {
        assert(_block > 0);
        uint256 _latest = latestRandomizeBlock;
        return ((_block > _latest)
            ? _latest
            // start search from the latest block
            : _searchPrevBlock(_block, __randomize_[_latest].prevBlock)
        );
    }

    /// Returns `true` only when the randomness request that got posted within given block was already
    /// reported back from the Witnet oracle, either successfully or with an error of any kind.
    function isRandomized(uint256 _block)
        public view
        virtual override
        returns (bool)
    {
        RandomizeData storage _data = __randomize_[_block];
        return (
            _data.witnetQueryId != 0 
                && _witnetCheckResultAvailability(_data.witnetQueryId)
        );
    }

    /// Generates a pseudo-random number uniformly distributed within the range [0 .. _range), by using 
    /// the given `_nonce` value and the randomness returned by `getRandomnessAfter(_block)`. 
    /// @dev Fails under same conditions as `getRandomnessAfter(uint256)` may do.
    /// @param _range Range within which the uniformly-distributed random number will be generated.
    /// @param _nonce Nonce value enabling multiple random numbers from the same randomness value.
    /// @param _block Block number from which the search will start.
    function random(uint32 _range, uint256 _nonce, uint256 _block)
        external view
        virtual override
        returns (uint32)
    {
        return random(
            _range,
            _nonce,
            keccak256(
                abi.encode(
                    msg.sender,
                    getRandomnessAfter(_block)
                )
            )
        );
    }

    /// Generates a pseudo-random number uniformly distributed within the range [0 .. _range), by using 
    /// the given `_nonce` value and the given `_seed` as a source of entropy.
    /// @param _range Range within which the uniformly-distributed random number will be generated.
    /// @param _nonce Nonce value enabling multiple random numbers from the same randomness value.
    /// @param _seed Seed value used as entropy source.
    function random(uint32 _range, uint256 _nonce, bytes32 _seed)
        public pure
        virtual override
        returns (uint32)
    {
        uint8 _flagBits = uint8(255 - _msbDeBruijn32(_range));
        uint256 _number = uint256(
                keccak256(
                    abi.encode(_seed, _nonce)
                )
            ) & uint256(2 ** _flagBits - 1);
        return uint32((_number * _range) >> _flagBits);
    }

    /// Requests the Witnet oracle to generate an EVM-agnostic and trustless source of randomness. 
    /// Only one randomness request per block will be actually posted to the WRB. Should there 
    /// already be a posted request within current block, all received funds shall be transfered
    /// back to the tx sender.
    function randomize()
        external payable
        virtual override
        returns (uint256 _id)
    {
        uint256 _unusedFee = msg.value;
        if (latestRandomizeBlock < block.number) {
            // Post the Witnet Randomness request:
            uint256 _fee;
            (_id, _fee) = _witnetPostRequest(witnetRandomnessRequest);
            // Keep Randomize data in storage:
            RandomizeData storage _data = __randomize_[block.number];
            _data.witnetQueryId = _id;
            _data.from = msg.sender;
            // Update block links:
            uint256 _prevBlock = latestRandomizeBlock;
            _data.prevBlock = _prevBlock;
            __randomize_[_prevBlock].nextBlock = block.number;
            latestRandomizeBlock = block.number;
            // Throw event:
            emit Randomized(
                msg.sender,
                _prevBlock,
                _data.witnetQueryId,
                witnetRandomnessRequest.hash()
            );
            _unusedFee -= _fee;
        }
        // Transfer back unused tx value:
        payable(msg.sender).transfer(_unusedFee);
    }

    /// Increases Witnet fee related to a pending-to-be-solved randomness request, as much as it
    /// may be required in proportion to how much bigger the current tx gas price is with respect the 
    /// highest gas price that was paid in either previous fee upgrades, or when the given randomness 
    /// request was posted.
    function upgradeRandomizeFee(uint256 _block)
        external payable
        virtual override
    {
        RandomizeData storage _data = __randomize_[_block];
        if (_data.witnetQueryId != 0) {
            uint256 _fundsToAdd = _witnetUpgradeReward(_data.witnetQueryId);
            if (_fundsToAdd > 0) {
                payable(msg.sender).transfer(msg.value - _fundsToAdd);
            }
        }
    }


    // ================================================================================================================
    // --- 'Clonable' overriden functions -----------------------------------------------------------------------------

    /// Deploys and returns the address of a minimal proxy clone that replicates contract
    /// behaviour while using its own EVM storage.
    /// @dev This function should always provide a new address, no matter how many times 
    /// @dev is actually called from the same `msg.sender`.
    function clone()
        public
        virtual override
        returns (Clonable _newInstance)
    {
        _newInstance = super.clone();
        _clone(_newInstance);
    }

    /// Deploys and returns the address of a minimal proxy clone that replicates contract 
    /// behaviour while using its own EVM storage.
    /// @dev This function uses the CREATE2 opcode and a `_salt` to deterministically deploy
    /// @dev the clone. Using the same `_salt` multiple time will revert, since
    /// @dev no contract can be deployed more than once at the same address.
    function cloneDeterministic(bytes32 _salt)
        public
        virtual override
        returns (Clonable _newInstance)
    {
        _newInstance = super.cloneDeterministic(_salt);
        _clone(_newInstance);
    }


    // ================================================================================================================
    // --- 'Initializable' overriden functions ------------------------------------------------------------------------

    /// @dev Initializes contract's storage context.
    function initialize(bytes memory _initData)
        public
        virtual override
    {
        require(address(witnetRandomnessRequest) == address(0), "WitnetRNG: already initialized");
        witnetRandomnessRequest = WitnetRequestRandomness(
            abi.decode(
                _initData,
                (address)
            )
        );
    }


    // ================================================================================================================
    // --- INTERNAL FUNCTIONS -----------------------------------------------------------------------------------------

    /// @dev Common steps for both deterministic and non-deterministic cloning.
    function _clone(Clonable _instance) internal {
        address _request = address(witnetRandomnessRequest.clone());
        Ownable(_request).transferOwnership(msg.sender);
        _instance.initialize(abi.encode(_request));
    }

    /// @dev Returns index of the Most Significant Bit of the given number, applying De Bruijn O(1) algorithm.
    function _msbDeBruijn32(uint32 _v)
        internal pure
        returns (uint8)
    {
        uint8[32] memory _bitPosition = [
                0, 9, 1, 10, 13, 21, 2, 29,
                11, 14, 16, 18, 22, 25, 3, 30,
                8, 12, 20, 28, 15, 17, 24, 7,
                19, 27, 23, 6, 26, 5, 4, 31
            ];
        _v |= _v >> 1;
        _v |= _v >> 2;
        _v |= _v >> 4;
        _v |= _v >> 8;
        _v |= _v >> 16;
        return _bitPosition[
            uint32(_v * uint256(0x07c4acdd)) >> 27
        ];
    }

    /// @dev Recursively searches for first block after the given one in which a Witnet Randomness request was casted.
    /// @dev Returns 0 if none found.
    function _searchNextBlock(uint256 _target, uint256 _latest) internal view returns (uint256) {
        return ((_target >= _latest) 
            ? __randomize_[_latest].nextBlock
            : _searchNextBlock(_target, __randomize_[_latest].prevBlock)
        );
    }

    /// @dev Recursively searches for first block before the given one in which a Witnet Randomness request was casted.
    /// @dev Returns 0 if none found.

    function _searchPrevBlock(uint256 _target, uint256 _latest) internal view returns (uint256) {
        return ((_target > _latest)
            ? _latest
            : _searchPrevBlock(_target, __randomize_[_latest].prevBlock)
        );
    }
}
